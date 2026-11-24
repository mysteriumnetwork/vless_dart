#include "core_process.h"

#include <vector>

namespace vless_dart {

namespace {

// Room for several commands without the writer ever having to wait on the
// core to drain the pipe.
constexpr DWORD kPipeBufferBytes = 1024 * 1024;

std::string LastErrorMessage(const char* what) {
  return std::string(what) + " failed with " +
         std::to_string(static_cast<unsigned long>(GetLastError()));
}

}  // namespace

CoreProcess::~CoreProcess() {
  Stop();
}

bool CoreProcess::Start(const std::wstring& exe_path, LineHandler on_line,
                        std::string* error) {
  if (running_.load()) {
    *error = "core is already running";
    return false;
  }

  // A previous core that exited on its own leaves its reader thread joinable
  // and its handles open. Assigning over a joinable std::thread terminates the
  // process, so reap it before starting another.
  if (reader_.joinable()) {
    Stop(kRestartGraceMs);
  }

  SECURITY_ATTRIBUTES inheritable = {};
  inheritable.nLength = sizeof(inheritable);
  inheritable.bInheritHandle = TRUE;

  HANDLE stdin_read = nullptr;
  HANDLE stdout_write = nullptr;
  // Sized well past the largest command rather than taking the ~4 KB default.
  // The core does not read stdin while it is bringing a tunnel up, and a
  // percent-encoded config is a few KB: with the default buffer a write from
  // the platform thread could block until the core came back, freezing the UI.
  if (!CreatePipe(&stdin_read, &stdin_write_, &inheritable, kPipeBufferBytes)) {
    *error = LastErrorMessage("CreatePipe(stdin)");
    return false;
  }
  if (!CreatePipe(&stdout_read_, &stdout_write, &inheritable,
                  kPipeBufferBytes)) {
    *error = LastErrorMessage("CreatePipe(stdout)");
    CloseHandle(stdin_read);
    CloseHandle(stdin_write_);
    stdin_write_ = nullptr;
    return false;
  }
  // Our ends must not reach the child, or the pipes never report EOF: the
  // child would hold a writer open against our own reader.
  SetHandleInformation(stdin_write_, HANDLE_FLAG_INHERIT, 0);
  SetHandleInformation(stdout_read_, HANDLE_FLAG_INHERIT, 0);

  job_ = CreateJobObjectW(nullptr, nullptr);
  if (job_ != nullptr) {
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits = {};
    limits.BasicLimitInformation.LimitFlags =
        JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    SetInformationJobObject(job_, JobObjectExtendedLimitInformation, &limits,
                            sizeof(limits));
  }

  STARTUPINFOW startup = {};
  startup.cb = sizeof(startup);
  startup.dwFlags = STARTF_USESTDHANDLES | STARTF_USESHOWWINDOW;
  startup.wShowWindow = SW_HIDE;
  startup.hStdInput = stdin_read;
  startup.hStdOutput = stdout_write;
  startup.hStdError = stdout_write;

  // CreateProcessW may write to the command line buffer, so it cannot be a
  // string literal or the exe path's own storage.
  std::vector<wchar_t> command_line(exe_path.begin(), exe_path.end());
  command_line.push_back(L'\0');

  PROCESS_INFORMATION process = {};
  const BOOL created = CreateProcessW(
      exe_path.c_str(), command_line.data(), nullptr, nullptr, TRUE,
      CREATE_NO_WINDOW | CREATE_SUSPENDED, nullptr, nullptr, &startup,
      &process);

  // The child owns its ends now, whether or not the launch worked.
  CloseHandle(stdin_read);
  CloseHandle(stdout_write);

  if (!created) {
    *error = LastErrorMessage("CreateProcess");
    CloseHandles();
    return false;
  }

  // Assigned while suspended so the core cannot outlive the job even if it
  // exits or spawns before we get here.
  if (job_ != nullptr) {
    AssignProcessToJobObject(job_, process.hProcess);
  }
  ResumeThread(process.hThread);
  CloseHandle(process.hThread);

  process_ = process.hProcess;
  on_line_ = std::move(on_line);
  running_.store(true);
  reader_ = std::thread(&CoreProcess::ReadLoop, this);
  return true;
}

void CoreProcess::Stop(DWORD grace_ms) {
  running_.store(false);

  // Closing stdin is the core's cue to unwind the tunnel. Terminating it
  // without this would leave the routes and the adapter behind.
  {
    std::lock_guard<std::mutex> lock(write_mutex_);
    if (stdin_write_ != nullptr) {
      CloseHandle(stdin_write_);
      stdin_write_ = nullptr;
    }
  }

  if (process_ != nullptr) {
    if (WaitForSingleObject(process_, grace_ms) != WAIT_OBJECT_0) {
      TerminateProcess(process_, 1);
      WaitForSingleObject(process_, 1000);
    }
  }

  // Joined unconditionally rather than behind the running_ flag: the core can
  // exit on its own, which clears the flag from the reader thread, and a
  // thread left joinable here would terminate the app at destruction.
  if (reader_.joinable()) {
    reader_.join();
  }
  CloseHandles();
}

bool CoreProcess::Send(const std::string& line) {
  std::lock_guard<std::mutex> lock(write_mutex_);
  if (stdin_write_ == nullptr) {
    return false;
  }
  const std::string payload = line + "\n";
  DWORD written = 0;
  size_t total = 0;
  while (total < payload.size()) {
    if (!WriteFile(stdin_write_, payload.data() + total,
                   static_cast<DWORD>(payload.size() - total), &written,
                   nullptr) ||
        written == 0) {
      return false;
    }
    total += written;
  }
  return true;
}

void CoreProcess::ReadLoop() {
  std::string pending;
  char buffer[4096];

  while (true) {
    DWORD read = 0;
    if (!ReadFile(stdout_read_, buffer, static_cast<DWORD>(sizeof(buffer)), &read,
                  nullptr) ||
        read == 0) {
      break;
    }
    pending.append(buffer, read);

    size_t start = 0;
    size_t newline = pending.find('\n', start);
    while (newline != std::string::npos) {
      std::string line = pending.substr(start, newline - start);
      if (!line.empty() && line.back() == '\r') {
        line.pop_back();
      }
      if (!line.empty() && on_line_) {
        on_line_(line);
      }
      start = newline + 1;
      newline = pending.find('\n', start);
    }
    pending.erase(0, start);
  }

  // Cleared here, not only in Stop: the core exiting on its own is the whole
  // reason it runs out of process, and leaving the flag set would make every
  // later connect fail to write to a pipe nothing is reading.
  running_.store(false);

  // Empty line means the core is gone, so whoever is waiting on it stops
  // waiting rather than hanging on a reply that will never come.
  if (on_line_) {
    on_line_(std::string());
  }
}

void CoreProcess::CloseHandles() {
  if (stdin_write_ != nullptr) {
    CloseHandle(stdin_write_);
    stdin_write_ = nullptr;
  }
  if (stdout_read_ != nullptr) {
    CloseHandle(stdout_read_);
    stdout_read_ = nullptr;
  }
  if (process_ != nullptr) {
    CloseHandle(process_);
    process_ = nullptr;
  }
  if (job_ != nullptr) {
    CloseHandle(job_);
    job_ = nullptr;
  }
}

}  // namespace vless_dart
