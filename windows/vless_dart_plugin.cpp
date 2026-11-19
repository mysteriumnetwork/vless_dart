#include "vless_dart_plugin.h"

#include <flutter/flutter_view.h>

#include <utility>

namespace vless_dart {

namespace {

constexpr char kControlChannel[] = "id.mysteriumvpn.vless_dart/vpncontrol";
constexpr char kStatusChannel[] = "id.mysteriumvpn.vless_dart/vpnstatus";

// The core sits beside the runner, which is also where wintun.dll lands: it is
// loaded with LOAD_LIBRARY_SEARCH_APPLICATION_DIR, so it has to be next to the
// executable that loads it rather than next to us.
constexpr wchar_t kCoreExecutable[] = L"vless_core.exe";

const flutter::EncodableValue* ValueOrNull(const flutter::EncodableMap& map,
                                           const char* key) {
  const auto it = map.find(flutter::EncodableValue(key));
  return it == map.end() ? nullptr : &it->second;
}

}  // namespace

void VlessDartPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows* registrar) {
  auto plugin = std::make_unique<VlessDartPlugin>(registrar);

  auto control = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      registrar->messenger(), kControlChannel,
      &flutter::StandardMethodCodec::GetInstance());
  control->SetMethodCallHandler(
      [raw = plugin.get()](const auto& call, auto result) {
        raw->HandleMethodCall(call, std::move(result));
      });

  auto status = std::make_unique<flutter::EventChannel<flutter::EncodableValue>>(
      registrar->messenger(), kStatusChannel,
      &flutter::StandardMethodCodec::GetInstance());
  status->SetStreamHandler(
      std::make_unique<flutter::StreamHandlerFunctions<flutter::EncodableValue>>(
          [raw = plugin.get()](
              const flutter::EncodableValue*,
              std::unique_ptr<flutter::EventSink<flutter::EncodableValue>>&&
                  events)
              -> std::unique_ptr<
                  flutter::StreamHandlerError<flutter::EncodableValue>> {
            raw->SetStatusSink(std::move(events));
            return nullptr;
          },
          [raw = plugin.get()](const flutter::EncodableValue*)
              -> std::unique_ptr<
                  flutter::StreamHandlerError<flutter::EncodableValue>> {
            raw->SetStatusSink(nullptr);
            return nullptr;
          }));

  // Keeps the channels alive for as long as the plugin, which outlives the
  // registrar's own handler registration.
  registrar->AddPlugin(std::move(plugin));
}

VlessDartPlugin::VlessDartPlugin(flutter::PluginRegistrarWindows* registrar)
    : registrar_(registrar) {
  // A system-wide unique id rather than WM_APP + n, which another plugin
  // hooking the same window is free to use for something else.
  wake_message_ = RegisterWindowMessageW(L"VlessDartCoreEvent");

  if (auto* view = registrar_->GetView()) {
    // The root, not the view itself. The runner parents the Flutter view to a
    // top-level window, and a top-level window proc delegate only ever sees
    // that window's messages — posting to the child would go nowhere.
    window_ = GetAncestor(view->GetNativeWindow(), GA_ROOT);
  }
  window_proc_id_ = registrar_->RegisterTopLevelWindowProcDelegate(
      [this](HWND, UINT message, WPARAM, LPARAM) -> std::optional<LRESULT> {
        if (message != wake_message_ || wake_message_ == 0) {
          return std::nullopt;
        }
        Drain();
        return 0;
      });
}

VlessDartPlugin::~VlessDartPlugin() {
  if (window_proc_id_ != -1) {
    registrar_->UnregisterTopLevelWindowProcDelegate(window_proc_id_);
  }
  // Before the queue and the pending results go away: Stop joins the reader
  // thread, so nothing can be appended after this returns.
  core_.Stop();
}

void VlessDartPlugin::SetStatusSink(
    std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> sink) {
  status_sink_ = std::move(sink);
  if (status_sink_) {
    // The stream is listened to after connect in practice, so replay the
    // current state rather than leaving the first event until something
    // changes.
    status_sink_->Success(flutter::EncodableValue(status_));
  }
}

void VlessDartPlugin::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const std::string& method = call.method_name();

  if (method == "initialize" || method == "setupTunnel") {
    // Nothing to prepare: Windows has no persistent tunnel profile, and the
    // Apple-only arguments are ignored exactly as they are on Android.
    result->Success(flutter::EncodableValue(true));
    return;
  }

  if (method == "checkTunnelConfiguration") {
    result->Success(flutter::EncodableValue(false));
    return;
  }

  if (method == "connect") {
    Connect(call, std::move(result));
    return;
  }

  if (method == "disconnect" || method == "removeTunnelConfiguration") {
    // The core is left running and torn down only in the destructor. Stopping
    // the process here would block the platform thread until it exited, and
    // the status the caller is waiting for arrives from the core anyway.
    if (!core_.Running() || !SendCommand({{"cmd", "stop"}})) {
      PublishStatus("disconnected");
    }
    result->Success(flutter::EncodableValue());
    return;
  }

  if (method == "status") {
    result->Success(flutter::EncodableValue(status_));
    return;
  }

  if (method == "tunnelStatistics") {
    Statistics(std::move(result));
    return;
  }

  result->NotImplemented();
}

void VlessDartPlugin::Connect(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const auto* arguments = std::get_if<flutter::EncodableMap>(call.arguments());
  const flutter::EncodableValue* config_value =
      arguments == nullptr ? nullptr : ValueOrNull(*arguments, "config");
  const auto* config =
      config_value == nullptr ? nullptr : std::get_if<std::string>(config_value);

  if (config == nullptr || config->empty()) {
    result->Error("err_config_empty", "No config provided");
    return;
  }

  std::string error;
  if (!EnsureCoreRunning(&error)) {
    result->Error("err_core_start", error);
    return;
  }

  if (!SendCommand({{"cmd", "start"}, {"config", *config}})) {
    result->Error("err_core_write", "the core is not accepting commands");
    return;
  }

  // Resolves once the tunnel has been requested to start, not once it is up,
  // matching Android. Failures arrive on the status stream.
  result->Success(flutter::EncodableValue());
}

void VlessDartPlugin::Statistics(
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (!core_.Running()) {
    result->Success(flutter::EncodableValue());
    return;
  }

  const std::string id = std::to_string(++next_request_id_);
  if (!SendCommand({{"cmd", "stats"}, {"id", id}})) {
    result->Success(flutter::EncodableValue());
    return;
  }
  pending_[id] = std::move(result);
}

bool VlessDartPlugin::EnsureCoreRunning(std::string* error) {
  if (core_.Running()) {
    return true;
  }
  return core_.Start(
      CoreExecutablePath(),
      [this](const std::string& line) { OnCoreLine(line); }, error);
}

bool VlessDartPlugin::SendCommand(const Fields& fields) {
  // Only the command name. The payload holds the Xray config, which carries
  // the session's VLESS id, and that must never reach a log.
  const auto command = fields.find("cmd");
  OutputDebugStringA(
      ("vless_dart -> " +
       (command == fields.end() ? std::string("?") : command->second) + "\n")
          .c_str());

  return core_.Send(Encode(fields));
}

void VlessDartPlugin::OnCoreLine(const std::string& line) {
  // Traced because a connect failure has nowhere else to go: connect resolves
  // as soon as the start is requested, matching Android, so the reason only
  // ever reaches the core's error event. Safe to trace — the core's output
  // never carries the config, and so never the session's VLESS id.
  OutputDebugStringA(("vless_dart <- " + (line.empty() ? "<core exited>" : line) + "\n").c_str());

  {
    std::lock_guard<std::mutex> lock(queue_mutex_);
    queue_.push_back(line);
  }
  // Never touch a channel from here: the embedder requires the platform
  // thread, so the work is handed to the window proc instead.
  if (window_ != nullptr && wake_message_ != 0) {
    PostMessageW(window_, wake_message_, 0, 0);
    return;
  }

  // No view to post to, which a hosted or headless embedding can produce.
  // Draining here breaks the platform-thread rule, but the alternative is a
  // status stream that never emits at all.
  Drain();
}

void VlessDartPlugin::Drain() {
  while (true) {
    std::string line;
    {
      std::lock_guard<std::mutex> lock(queue_mutex_);
      if (queue_.empty()) {
        return;
      }
      line = std::move(queue_.front());
      queue_.pop_front();
    }

    if (line.empty()) {
      // The core exited. Anything still waiting on it never gets an answer.
      FailPending("the core exited");
      PublishStatus("disconnected");
      continue;
    }

    Fields fields;
    if (Decode(line, &fields)) {
      Dispatch(fields);
    }
  }
}

void VlessDartPlugin::Dispatch(const Fields& fields) {
  const auto event = fields.find("event");
  if (event == fields.end()) {
    return;
  }

  if (event->second == "status") {
    const auto status = fields.find("status");
    if (status != fields.end()) {
      PublishStatus(status->second);
    }
    return;
  }

  if (event->second == "stats") {
    const auto id = fields.find("id");
    if (id == fields.end()) {
      return;
    }
    const auto waiting = pending_.find(id->second);
    if (waiting == pending_.end()) {
      return;
    }
    const auto uplink = fields.find("uplink");
    const auto downlink = fields.find("downlink");
    // latestHandshake has no meaning for VLESS and footprintBytes is an iOS
    // concern, so both are left out and default on the Dart side.
    const std::string json =
        "{\"totalUpload\":" +
        (uplink == fields.end() ? std::string("0") : uplink->second) +
        ",\"totalDownload\":" +
        (downlink == fields.end() ? std::string("0") : downlink->second) + "}";
    waiting->second->Success(flutter::EncodableValue(json));
    pending_.erase(waiting);
    return;
  }

  if (event->second == "error") {
    const auto id = fields.find("id");
    if (id == fields.end()) {
      return;
    }
    const auto waiting = pending_.find(id->second);
    if (waiting == pending_.end()) {
      return;
    }
    const auto message = fields.find("message");
    waiting->second->Error(
        "err_core",
        message == fields.end() ? std::string("core error") : message->second);
    pending_.erase(waiting);
  }
}

void VlessDartPlugin::PublishStatus(const std::string& status) {
  if (status == status_) {
    return;
  }
  status_ = status;
  if (status_sink_) {
    status_sink_->Success(flutter::EncodableValue(status_));
  }
}

void VlessDartPlugin::FailPending(const std::string& message) {
  for (auto& [id, result] : pending_) {
    result->Error("err_core", message);
  }
  pending_.clear();
}

std::wstring VlessDartPlugin::CoreExecutablePath() {
  wchar_t module[MAX_PATH] = {};
  const DWORD length = GetModuleFileNameW(nullptr, module, MAX_PATH);
  std::wstring path(module, length);
  const size_t slash = path.find_last_of(L'\\');
  if (slash == std::wstring::npos) {
    return kCoreExecutable;
  }
  return path.substr(0, slash + 1) + kCoreExecutable;
}

}  // namespace vless_dart
