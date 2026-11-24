#include "vless_dart_plugin.h"

#include <utility>

namespace vless_dart {

namespace {

constexpr char kControlChannel[] = "id.mysteriumvpn.vless_dart/vpncontrol";
constexpr char kStatusChannel[] = "id.mysteriumvpn.vless_dart/vpnstatus";

// The core sits beside the runner, which is also where wintun.dll lands: it is
// loaded with LOAD_LIBRARY_SEARCH_APPLICATION_DIR, so it has to be next to the
// executable that loads it rather than next to us.
constexpr wchar_t kCoreExecutable[] = L"vless_core.exe";

// Registered once per process; a second engine reuses it.
constexpr wchar_t kWakeWindowClass[] = L"VlessDartWakeWindow";

// A counter the wire did not carry, or carried as anything but digits, would
// otherwise be interpolated straight into the JSON and make it unparseable --
// which Dart swallows, reporting zero bytes with no diagnostic anywhere.
std::string Counter(Fields::const_iterator found, Fields::const_iterator end) {
  if (found == end || found->second.empty()) {
    return "0";
  }
  for (const char c : found->second) {
    if (c < '0' || c > '9') {
      return "0";
    }
  }
  return found->second;
}

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

// The registrar is not retained: the channels are set up in
// RegisterWithRegistrar and the wake window is the plugin's own.
VlessDartPlugin::VlessDartPlugin(flutter::PluginRegistrarWindows*) {
  // A system-wide unique id rather than WM_APP + n, which another plugin
  // hooking the same window is free to use for something else.
  wake_message_ = RegisterWindowMessageW(L"VlessDartCoreEvent");

  // A message-only window of our own rather than the runner's.
  //
  // The obvious route is RegisterTopLevelWindowProcDelegate plus a post to
  // the view's root window, and it depends on two things the embedder does
  // not promise: that registrar->GetView() is non-null, which is false in
  // hosted and headless embeddings, and that the delegate sees a message
  // posted to whatever GetAncestor reports. This window depends on neither.
  //
  // Created here because plugin registration runs on the platform thread, so
  // the window belongs to it and the runner's own GetMessage loop -- which
  // pumps every window on the thread -- dispatches to it. That is what puts
  // Drain() on the platform thread, where the channels must be touched.
  WNDCLASSEXW window_class = {};
  window_class.cbSize = sizeof(window_class);
  window_class.lpfnWndProc = WakeWindowProc;
  window_class.hInstance = GetModuleHandleW(nullptr);
  window_class.lpszClassName = kWakeWindowClass;
  // A repeat registration fails with ERROR_CLASS_ALREADY_EXISTS, which is the
  // expected result for a second engine in the same process and not a fault.
  RegisterClassExW(&window_class);

  window_ = CreateWindowExW(0, kWakeWindowClass, nullptr, 0, 0, 0, 0, 0,
                            HWND_MESSAGE, nullptr, window_class.hInstance,
                            this);
  if (window_ == nullptr) {
    OutputDebugStringA(
        "vless_dart: no wake window; core events drain off the platform "
        "thread\n");
  }
}

LRESULT CALLBACK VlessDartPlugin::WakeWindowProc(HWND window, UINT message,
                                                 WPARAM wparam,
                                                 LPARAM lparam) {
  if (message == WM_NCCREATE) {
    auto* create = reinterpret_cast<CREATESTRUCTW*>(lparam);
    SetWindowLongPtrW(window, GWLP_USERDATA,
                      reinterpret_cast<LONG_PTR>(create->lpCreateParams));
    return DefWindowProcW(window, message, wparam, lparam);
  }

  auto* self = reinterpret_cast<VlessDartPlugin*>(
      GetWindowLongPtrW(window, GWLP_USERDATA));
  if (self != nullptr && self->wake_message_ != 0 &&
      message == self->wake_message_) {
    self->Drain();
    return 0;
  }
  return DefWindowProcW(window, message, wparam, lparam);
}

VlessDartPlugin::~VlessDartPlugin() {
  // Stop first, window second. Stop joins the reader thread, so nothing can
  // be appended after it returns -- and while the window still exists the
  // reader posts to it rather than taking OnCoreLine's fallback, which would
  // drain on the reader thread and touch channels during engine teardown.
  // Whatever it posts is simply never dispatched.
  core_.Stop();
  if (window_ != nullptr) {
    DestroyWindow(window_);
    window_ = nullptr;
  }
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
    // Truthfully, not a constant false. The app takes setupTunnel on every
    // connect when this says no, and that path can call
    // _resolveExistingConnection, whose failure handler disconnects a tunnel
    // that is already up -- tearing one down mid-connect on a reconnect.
    result->Success(flutter::EncodableValue(core_.Running()));
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
      continue;
    }
    // Not a protocol line, and deliberately not surfaced. Xray's own logger
    // writes to this same stdout, so a routine warning -- the WebSocket
    // transport deprecation notice arrives on every connect -- would reach
    // the app as a failure. It is traced in OnCoreLine either way.
    //
    // A Go panic also arrives this way and is worth surfacing, but telling
    // the two apart needs the core's stderr on a pipe of its own rather than
    // a guess about the text.
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
      // Nothing in flight can still be answered once the tunnel is down, and
      // the core is deliberately left running after a disconnect -- so
      // without this a core that stops replying leaks one MethodResult per
      // stats poll, about one a second, for the rest of the session.
      if (status->second == "disconnected") {
        FailPending("the tunnel stopped");
      }
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
    const std::string json = "{\"totalUpload\":" +
                             Counter(uplink, fields.end()) +
                             ",\"totalDownload\":" +
                             Counter(downlink, fields.end()) + "}";
    waiting->second->Success(flutter::EncodableValue(json));
    pending_.erase(waiting);
    return;
  }

  if (event->second == "error") {
    const auto message = fields.find("message");
    const std::string text =
        message == fields.end() ? std::string("core error") : message->second;

    // An id means a request failed, and its caller is the one waiting.
    const auto id = fields.find("id");
    if (id != fields.end()) {
      const auto waiting = pending_.find(id->second);
      if (waiting != pending_.end()) {
        waiting->second->Error("err_core", text);
        pending_.erase(waiting);
        return;
      }
    }

    // Otherwise nobody is: connect() resolves as soon as the start is
    // requested, matching Android, and the status that follows is only
    // "disconnected" -- which PublishStatus drops when it already is that.
    // Without this the failure has no route out at all.
    if (status_sink_) {
      status_sink_->Error("core_error", text);
    }
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
