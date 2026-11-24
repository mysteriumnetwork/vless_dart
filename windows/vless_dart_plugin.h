#ifndef FLUTTER_PLUGIN_VLESS_DART_PLUGIN_H_
#define FLUTTER_PLUGIN_VLESS_DART_PLUGIN_H_

#include <flutter/event_channel.h>
#include <flutter/event_sink.h>
#include <flutter/event_stream_handler_functions.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>
#include <windows.h>

#include <deque>
#include <memory>
#include <mutex>
#include <optional>
#include <string>

#include "core_process.h"
#include "wire.h"

namespace vless_dart {

class VlessDartPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar);

  explicit VlessDartPlugin(flutter::PluginRegistrarWindows* registrar);
  ~VlessDartPlugin() override;

  VlessDartPlugin(const VlessDartPlugin&) = delete;
  VlessDartPlugin& operator=(const VlessDartPlugin&) = delete;

  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  void SetStatusSink(
      std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> sink);

 private:
  void Connect(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void Statistics(
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  bool EnsureCoreRunning(std::string* error);
  bool SendCommand(const Fields& fields);

  // Called on the reader thread; queues the line and wakes the platform
  // thread. Everything that touches a channel happens in Drain().
  void OnCoreLine(const std::string& line);
  void Drain();
  void Dispatch(const Fields& fields);
  void PublishStatus(const std::string& status);
  void FailPending(const std::string& message);

  static std::wstring CoreExecutablePath();
  static LRESULT CALLBACK WakeWindowProc(HWND window, UINT message,
                                         WPARAM wparam, LPARAM lparam);

  // A message-only window of the plugin's own, created on the platform
  // thread. See the constructor for why the runner's window is not used.
  HWND window_ = nullptr;
  UINT wake_message_ = 0;

  CoreProcess core_;

  std::mutex queue_mutex_;
  std::deque<std::string> queue_;

  // Touched only on the platform thread, where every channel call is made.
  std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> status_sink_;
  std::string status_ = "disconnected";
  std::map<std::string,
           std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>>
      pending_;
  int64_t next_request_id_ = 0;
};

}  // namespace vless_dart

#endif  // FLUTTER_PLUGIN_VLESS_DART_PLUGIN_H_
