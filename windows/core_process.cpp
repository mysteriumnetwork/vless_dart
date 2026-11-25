#include "core_process.h"

#include <vector>

namespace vless_dart {

namespace {

// Room for several commands without the writer ever having to wait on the
// core to drain the pipe.
constexpr DWORD kPipeBufferBytes = 1024 * 1024;

// Far past any line of the protocol: a status, a pair of counters, an error
// message. Output with no newline in it is not the protocol, and without a
// bound it would be held in memory for as long as it kept coming.
constexpr size_t kMaxLineBytes = 64 * 1024;

// How long the reader waits, once the core's output has ended, for the
// process itself to finish so its exit code can be read.
constexpr DWORD kExitCodeWaitMs = 2000;

// The longest path Windows accepts, in characters.
constexpr size_t kMaxPathChars = 32768;

std::string LastErrorMessage(const char* what) {
  return std::string(what) + " failed with " +
         std::to_string(static_cast<unsigned long>(GetLastError()));
}

// Null if the job cannot be made to kill on close, since a job without that
// limit is no use here.
HANDLE CreateKillOnCloseJob() {
  HANDLE job = CreateJobObjectW(nullptr, nullptr);
  if (job == nullptr) {
    return nullptr;
  }
  JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits = {};
  limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
  if (!SetInformationJobObject(job, JobObjectExtendedLimitInformation, &limits,
                               sizeof(limits))) {
    CloseHandle(job);
    return nullptr;
  }
  return job;
}

}  // namespace

std::wstring SiblingPath(const std::wstring& module_path,
                         const std::wstring& name) {
  const size_t slash = module_path.find_last_of(L"\\/");
  if (slash == std::wstring::npos) {
    return std::wstring();
  }
  return module_path.substr(0, slash + 1) + name;
}

std::wstring ModulePath() {
  // GetModuleFileNameW truncates a path that does not fit and still reports
  // success, and a truncated path is a different path. Grow until it fits.
  std::wstring path(MAX_PATH, L'\0');
  while (true) {
    const DWORD length = GetModuleFileNameW(
        nullptr, path.data(), static_cast<DWORD>(path.size()));
    if (length == 0) {
      return std::wstring();
    }
    if (length < path.size()) {
      path.resize(length);
      return path;
    }
    if (path.size() >= kMaxPathChars) {
      return std::wstring();
    }
    path.resize(path.size() * 2);
  }
}

CoreProcess::~CoreProcess() {
  Stop();
}

bool CoreProcess::Start(const std::wstring& exe_path, LineHandler on_line,
                        std::string* error) {
  if (running_.load()) {
    *error = "core is already running";
    return false;
  }
  if (exe_path.empty()) {
    *error = "the core's location could not be resolved";
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

  job_ = CreateKillOnCloseJob();

  // The child gets these two handles and nothing else. Asking only for
  // inheritance hands it every inheritable handle in this process, whoever
  // opened it: another plugin's pipe to its own child, say, which then never
  // reports EOF because an elevated core it has never heard of holds a copy.
  HANDLE inherited[] = {stdin_read, stdout_write};
  SIZE_T attribute_bytes = 0;
  InitializeProcThreadAttributeList(nullptr, 1, 0, &attribute_bytes);
  std::vector<unsigned char> attribute_storage(attribute_bytes);
  const auto attributes = reinterpret_cast<LPPROC_THREAD_ATTRIBUTE_LIST>(
      attribute_storage.data());
  if (attribute_bytes == 0 ||
      !InitializeProcThreadAttributeList(attributes, 1, 0, &attribute_bytes)) {
    *error = LastErrorMessage("InitializeProcThreadAttributeList");
    CloseHandle(stdin_read);
    CloseHandle(stdout_write);
    CloseHandles();
    return false;
  }

  PROCESS_INFORMATION process = {};
  BOOL created = FALSE;
  if (!UpdateProcThreadAttribute(attributes, 0,
                                 PROC_THREAD_ATTRIBUTE_HANDLE_LIST, inherited,
                                 sizeof(inherited), nullptr, nullptr)) {
    *error = LastErrorMessage("UpdateProcThreadAttribute");
  } else {
    STARTUPINFOEXW startup = {};
    startup.StartupInfo.cb = sizeof(startup);
    startup.StartupInfo.dwFlags = STARTF_USESTDHANDLES | STARTF_USESHOWWINDOW;
    startup.StartupInfo.wShowWindow = SW_HIDE;
    startup.StartupInfo.hStdInput = stdin_read;
    startup.StartupInfo.hStdOutput = stdout_write;
    startup.StartupInfo.hStdError = stdout_write;
    startup.lpAttributeList = attributes;

    // Quoted, because the child splits this on spaces to find its own name
    // and the app installs under "Program Files". A buffer of its own,
    // because CreateProcessW may write to it.
    const std::wstring quoted = L"\"" + exe_path + L"\"";
    std::vector<wchar_t> command_line(quoted.begin(), quoted.end());
    command_line.push_back(L'\0');

    created = CreateProcessW(
        exe_path.c_str(), command_line.data(), nullptr, nullptr, TRUE,
        CREATE_NO_WINDOW | CREATE_SUSPENDED | EXTENDED_STARTUPINFO_PRESENT,
        nullptr, nullptr, &startup.StartupInfo, &process);
    if (!created) {
      // Read before anything below can replace it.
      *error = LastErrorMessage("CreateProcess");
    }
  }
  DeleteProcThreadAttributeList(attributes);

  // The child owns its ends now, whether or not the launch worked.
  CloseHandle(stdin_read);
  CloseHandle(stdout_write);

  if (!created) {
    CloseHandles();
    return false;
  }

  // Assigned while suspended so the core cannot outlive the job even if it
  // exits or spawns before we get here.
  if (job_ == nullptr || !AssignProcessToJobObject(job_, process.hProcess)) {
    // Not fatal. The core still unwinds when its stdin closes, and that
    // happens when this process dies too. What is lost is the backstop for a
    // core too stuck to notice, so it is worth a line in the debugger.
    OutputDebugStringA(
        "vless_dart: the core is not in a kill-on-close job\n");
    if (job_ != nullptr) {
      CloseHandle(job_);
      job_ = nullptr;
    }
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

  // Whatever the core started goes with it, and before the join rather than
  // when the job handle closes after it. A child of the core inherits its
  // stdout, and the reader below only finishes once the last copy of that
  // pipe is closed: left alive, such a child would hang this thread, which is
  // the platform thread.
  if (job_ != nullptr) {
    TerminateJobObject(job_, 1);
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
    if (pending.size() > kMaxLineBytes) {
      // Dropped, and the rest of it will be when its newline arrives: no
      // protocol line is this long, so nothing that parses is lost.
      pending.clear();
    }
  }

  // Cleared here, not only in Stop: the core exiting on its own is the whole
  // reason it runs out of process, and leaving the flag set would make every
  // later connect fail to write to a pipe nothing is reading.
  running_.store(false);

  // The pipe closes a moment before the process is gone, so give it that
  // moment. process_ is only replaced after this thread has been joined.
  DWORD code = STILL_ACTIVE;
  if (WaitForSingleObject(process_, kExitCodeWaitMs) == WAIT_OBJECT_0) {
    GetExitCodeProcess(process_, &code);
  }
  exit_code_.store(code);

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
