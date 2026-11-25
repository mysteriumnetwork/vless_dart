// A stand-in for vless_core.exe, for core_process_test.cpp.
//
// CoreProcess launches its child with no arguments, so the behaviour to act
// out comes from the environment, which the child inherits.

#include <windows.h>

#include <cstdint>
#include <cstdlib>
#include <string>

namespace {

constexpr char kModeVariable[] = "VLESS_DART_TEST_HELPER";
constexpr char kHandleVariable[] = "VLESS_DART_TEST_HANDLE";

std::string Variable(const char* name) {
  char buffer[128] = {};
  const DWORD length =
      GetEnvironmentVariableA(name, buffer, static_cast<DWORD>(sizeof(buffer)));
  if (length == 0 || length >= sizeof(buffer)) {
    return std::string();
  }
  return std::string(buffer, length);
}

void Write(const std::string& bytes) {
  const HANDLE out = GetStdHandle(STD_OUTPUT_HANDLE);
  size_t total = 0;
  while (total < bytes.size()) {
    DWORD written = 0;
    if (!WriteFile(out, bytes.data() + total,
                   static_cast<DWORD>(bytes.size() - total), &written,
                   nullptr) ||
        written == 0) {
      return;
    }
    total += written;
  }
}

void Say(const std::string& line) {
  Write(line + "\n");
}

// Echoes each line of stdin until it closes, which is how the plugin asks the
// core to stop.
void EchoUntilStdinCloses() {
  const HANDLE in = GetStdHandle(STD_INPUT_HANDLE);
  std::string pending;
  char buffer[512];
  for (;;) {
    DWORD read = 0;
    if (!ReadFile(in, buffer, static_cast<DWORD>(sizeof(buffer)), &read,
                  nullptr) ||
        read == 0) {
      return;
    }
    pending.append(buffer, read);
    size_t newline = pending.find('\n');
    while (newline != std::string::npos) {
      Say("echo:" + pending.substr(0, newline));
      pending.erase(0, newline + 1);
      newline = pending.find('\n');
    }
  }
}

// Starts a copy of this program that never exits and that holds a copy of our
// stdout, as anything the real core launched would.
bool SpawnStubbornChild(DWORD* pid) {
  wchar_t self[MAX_PATH] = {};
  const DWORD length = GetModuleFileNameW(nullptr, self, MAX_PATH);
  if (length == 0 || length >= MAX_PATH) {
    return false;
  }
  SetEnvironmentVariableA(kModeVariable, "stubborn");

  STARTUPINFOW startup = {};
  startup.cb = sizeof(startup);
  startup.dwFlags = STARTF_USESTDHANDLES;
  startup.hStdInput = nullptr;
  startup.hStdOutput = GetStdHandle(STD_OUTPUT_HANDLE);
  startup.hStdError = GetStdHandle(STD_ERROR_HANDLE);

  PROCESS_INFORMATION child = {};
  if (!CreateProcessW(self, nullptr, nullptr, nullptr, TRUE, CREATE_NO_WINDOW,
                      nullptr, nullptr, &startup, &child)) {
    return false;
  }
  *pid = child.dwProcessId;
  CloseHandle(child.hThread);
  CloseHandle(child.hProcess);
  return true;
}

}  // namespace

int main() {
  const std::string mode = Variable(kModeVariable);

  if (mode == "echo") {
    EchoUntilStdinCloses();
    Say("bye");
    return 0;
  }

  if (mode == "exit") {
    Say("hello");
    return 3;
  }

  if (mode == "stubborn") {
    // Ignores stdin closing, like a core stuck in its teardown.
    Say("ready");
    Sleep(INFINITE);
    return 0;
  }

  if (mode == "parent") {
    DWORD pid = 0;
    if (!SpawnStubbornChild(&pid)) {
      Say("spawn-failed " + std::to_string(GetLastError()));
      return 2;
    }
    Say("spawned " + std::to_string(pid));
    // Exits promptly once asked, leaving the child behind with the pipe.
    EchoUntilStdinCloses();
    return 0;
  }

  if (mode == "probe") {
    // The value of a handle the test holds. It is only ours as well if it
    // was inherited, and then this signals the test's own event.
    const std::string value = Variable(kHandleVariable);
    const auto handle = reinterpret_cast<HANDLE>(
        static_cast<uintptr_t>(std::strtoull(value.c_str(), nullptr, 10)));
    Say(SetEvent(handle) ? "probe:set" : "probe:refused");
    EchoUntilStdinCloses();
    return 0;
  }

  if (mode == "flood") {
    // Far more than a line of the protocol, with no newline in it.
    Write(std::string(300 * 1024, 'x'));
    Say("");
    Say("after");
    EchoUntilStdinCloses();
    return 0;
  }

  Say("unknown mode '" + mode + "'");
  return 2;
}
