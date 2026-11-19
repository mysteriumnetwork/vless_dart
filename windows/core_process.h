#ifndef FLUTTER_PLUGIN_VLESS_DART_CORE_PROCESS_H_
#define FLUTTER_PLUGIN_VLESS_DART_CORE_PROCESS_H_

#include <windows.h>

#include <atomic>
#include <functional>
#include <mutex>
#include <string>
#include <thread>

namespace vless_dart {

// Runs vless_core.exe and speaks the line protocol to it over stdin/stdout.
//
// The core is a child process rather than a library because a Go panic there
// calls os.Exit; out of process that costs a tunnel, in process it would cost
// the app.
class CoreProcess {
 public:
  // Called on the reader thread for every line the core writes, and with an
  // empty string once the core has exited.
  using LineHandler = std::function<void(const std::string&)>;

  CoreProcess() = default;
  ~CoreProcess();

  CoreProcess(const CoreProcess&) = delete;
  CoreProcess& operator=(const CoreProcess&) = delete;

  // Launches |exe_path|. Returns false and fills |error| on failure.
  bool Start(const std::wstring& exe_path, LineHandler on_line,
             std::string* error);

  // Closes stdin so the core tears the tunnel down on its own, waits briefly,
  // then terminates. Safe to call when nothing is running.
  void Stop();

  bool Running() const { return running_.load(); }

  // Writes one line. Returns false if the core is gone.
  bool Send(const std::string& line);

 private:
  void ReadLoop();
  void CloseHandles();

  // Kills the core if the app dies without calling Stop: the tunnel would
  // otherwise outlive the app, with the machine still routed into it.
  HANDLE job_ = nullptr;
  HANDLE process_ = nullptr;
  HANDLE stdin_write_ = nullptr;
  HANDLE stdout_read_ = nullptr;

  std::thread reader_;
  std::atomic<bool> running_{false};
  LineHandler on_line_;
  std::mutex write_mutex_;
};

}  // namespace vless_dart

#endif  // FLUTTER_PLUGIN_VLESS_DART_CORE_PROCESS_H_
