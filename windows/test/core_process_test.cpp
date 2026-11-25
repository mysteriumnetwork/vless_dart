#include "core_process.h"

#include <gtest/gtest.h>

#include <algorithm>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace vless_dart {
namespace {

// Built beside this runner by windows/CMakeLists.txt.
constexpr wchar_t kHelper[] = L"vless_dart_test_helper.exe";
constexpr char kModeVariable[] = "VLESS_DART_TEST_HELPER";
constexpr char kHandleVariable[] = "VLESS_DART_TEST_HANDLE";

// What the handler records for the empty line CoreProcess sends on exit.
constexpr char kExited[] = "<exited>";

constexpr std::chrono::seconds kPatience(15);

// What the reader thread has delivered, with a way to wait for more.
class Lines {
 public:
  void Add(const std::string& line) {
    {
      std::lock_guard<std::mutex> lock(mutex_);
      lines_.push_back(line);
    }
    changed_.notify_all();
  }

  bool WaitFor(const std::string& line) {
    std::unique_lock<std::mutex> lock(mutex_);
    return changed_.wait_for(lock, kPatience, [&] {
      return std::find(lines_.begin(), lines_.end(), line) != lines_.end();
    });
  }

  // Waits for a line that starts with |prefix| and stores the rest of it.
  bool WaitForPrefix(const std::string& prefix, std::string* rest) {
    std::unique_lock<std::mutex> lock(mutex_);
    return changed_.wait_for(lock, kPatience, [&] {
      for (const std::string& line : lines_) {
        if (line.compare(0, prefix.size(), prefix) == 0) {
          *rest = line.substr(prefix.size());
          return true;
        }
      }
      return false;
    });
  }

  bool Has(const std::string& line) {
    std::lock_guard<std::mutex> lock(mutex_);
    return std::find(lines_.begin(), lines_.end(), line) != lines_.end();
  }

  size_t LongestLine() {
    std::lock_guard<std::mutex> lock(mutex_);
    size_t longest = 0;
    for (const std::string& line : lines_) {
      // Not std::max: windows.h defines max as a macro under MSVC.
      if (line.size() > longest) {
        longest = line.size();
      }
    }
    return longest;
  }

 private:
  std::mutex mutex_;
  std::condition_variable changed_;
  std::vector<std::string> lines_;
};

// Runs |work| on a thread of its own and reports whether it finished in time.
bool FinishesWithin(std::chrono::seconds limit, std::function<void()> work) {
  struct State {
    std::mutex mutex;
    std::condition_variable done;
    bool finished = false;
  };
  auto state = std::make_shared<State>();
  std::thread([state, work = std::move(work)] {
    work();
    {
      std::lock_guard<std::mutex> lock(state->mutex);
      state->finished = true;
    }
    state->done.notify_all();
  }).detach();

  std::unique_lock<std::mutex> lock(state->mutex);
  return state->done.wait_for(lock, limit, [&] { return state->finished; });
}

class CoreProcessTest : public ::testing::Test {
 protected:
  bool Start(const char* mode) {
    SetEnvironmentVariableA(kModeVariable, mode);
    std::string error;
    const bool started = core_.Start(
        SiblingPath(ModulePath(), kHelper),
        [this](const std::string& line) {
          lines_.Add(line.empty() ? kExited : line);
        },
        &error);
    EXPECT_TRUE(started) << error;
    return started;
  }

  // A Stop that never returns is what several of these tests exist to catch,
  // and it runs on the platform thread in the app. It cannot be allowed to
  // hang the run either: the thread it is stuck on cannot be abandoned
  // safely, so the whole process goes, and the job takes the helpers with it.
  void StopOrDie(DWORD grace_ms) {
    if (FinishesWithin(kPatience, [this, grace_ms] { core_.Stop(grace_ms); })) {
      return;
    }
    std::fprintf(stderr, "CoreProcess::Stop did not return within %lld s\n",
                 static_cast<long long>(kPatience.count()));
    std::fflush(stderr);
    TerminateProcess(GetCurrentProcess(), 1);
  }

  // Declared before the process, so it outlives the reader thread that the
  // process's destructor joins.
  Lines lines_;
  CoreProcess core_;
};

TEST(SiblingPath, NamesAFileInTheSameDirectory) {
  EXPECT_EQ(SiblingPath(L"C:\\Program Files\\App\\app.exe", L"vless_core.exe"),
            L"C:\\Program Files\\App\\vless_core.exe");
  EXPECT_EQ(SiblingPath(L"C:/App/app.exe", L"vless_core.exe"),
            L"C:/App/vless_core.exe");
}

// A bare name would be resolved against the current directory, by a process
// that runs elevated.
TEST(SiblingPath, IsEmptyRatherThanABareName) {
  EXPECT_TRUE(SiblingPath(L"app.exe", L"vless_core.exe").empty());
  EXPECT_TRUE(SiblingPath(L"", L"vless_core.exe").empty());
}

TEST(ModulePath, IsThisExecutable) {
  const std::wstring path = ModulePath();
  ASSERT_FALSE(path.empty());
  EXPECT_NE(GetFileAttributesW(path.c_str()), INVALID_FILE_ATTRIBUTES);
  EXPECT_NE(path.find(L"vless_dart_test"), std::wstring::npos);
}

TEST_F(CoreProcessTest, RefusesToStartWithoutAPath) {
  std::string error;
  EXPECT_FALSE(core_.Start(std::wstring(), [](const std::string&) {}, &error));
  EXPECT_FALSE(error.empty());
  EXPECT_FALSE(core_.Running());
}

TEST_F(CoreProcessTest, CarriesLinesBothWays) {
  ASSERT_TRUE(Start("echo"));
  EXPECT_TRUE(core_.Running());

  ASSERT_TRUE(core_.Send("event=status status=connected"));
  EXPECT_TRUE(lines_.WaitFor("echo:event=status status=connected"));

  StopOrDie(CoreProcess::kDefaultShutdownGraceMs);

  // Stop asks by closing stdin, and the helper only says this once it has
  // seen that: the core was given the chance to unwind, not just killed.
  EXPECT_TRUE(lines_.Has("bye"));
  EXPECT_TRUE(lines_.Has(kExited));
  EXPECT_FALSE(core_.Running());
  EXPECT_FALSE(core_.Send("too late"));
}

TEST_F(CoreProcessTest, NoticesACoreThatExitsAndStartsAnother) {
  ASSERT_TRUE(Start("exit"));
  ASSERT_TRUE(lines_.WaitFor("hello"));
  ASSERT_TRUE(lines_.WaitFor(kExited));
  // Cleared before the exit is reported, or the next connect would write to
  // a pipe nothing reads.
  EXPECT_FALSE(core_.Running());
  // The helper's own, which is what the plugin tells the app when a core
  // dies under a tunnel.
  EXPECT_EQ(core_.ExitCode(), static_cast<DWORD>(3));

  // The first reader thread is still joinable here, which is the state a
  // restart has to cope with.
  ASSERT_TRUE(Start("echo"));
  ASSERT_TRUE(core_.Send("again"));
  EXPECT_TRUE(lines_.WaitFor("echo:again"));

  StopOrDie(CoreProcess::kDefaultShutdownGraceMs);
}

TEST_F(CoreProcessTest, KillsACoreThatIgnoresItsStdin) {
  ASSERT_TRUE(Start("stubborn"));
  ASSERT_TRUE(lines_.WaitFor("ready"));

  StopOrDie(200);

  EXPECT_TRUE(lines_.Has(kExited));
  EXPECT_FALSE(core_.Running());
  // What Stop terminates it with.
  EXPECT_EQ(core_.ExitCode(), static_cast<DWORD>(1));
}

TEST_F(CoreProcessTest, DoesNotWaitOnWhatTheCoreStarted) {
  ASSERT_TRUE(Start("parent"));
  std::string pid_text;
  ASSERT_TRUE(lines_.WaitForPrefix("spawned ", &pid_text));
  const auto pid =
      static_cast<DWORD>(std::strtoul(pid_text.c_str(), nullptr, 10));
  const HANDLE grandchild = OpenProcess(SYNCHRONIZE, FALSE, pid);
  ASSERT_NE(grandchild, nullptr);
  // The grandchild is up, and holds a copy of the core's stdout.
  ASSERT_TRUE(lines_.WaitFor("ready"));

  // The helper exits as soon as it is asked. Its child never does, and the
  // reader cannot finish while that copy of the pipe is open.
  StopOrDie(CoreProcess::kRestartGraceMs);

  EXPECT_EQ(WaitForSingleObject(grandchild, 5000), WAIT_OBJECT_0);
  CloseHandle(grandchild);
  EXPECT_TRUE(lines_.Has(kExited));
}

TEST_F(CoreProcessTest, HandsTheCoreItsPipesAndNothingElse) {
  SECURITY_ATTRIBUTES inheritable = {};
  inheritable.nLength = sizeof(inheritable);
  inheritable.bInheritHandle = TRUE;
  // Stands in for a handle some other part of the app left inheritable.
  const HANDLE bystander = CreateEventW(&inheritable, TRUE, FALSE, nullptr);
  ASSERT_NE(bystander, nullptr);
  SetEnvironmentVariableA(
      kHandleVariable,
      std::to_string(reinterpret_cast<uintptr_t>(bystander)).c_str());

  ASSERT_TRUE(Start("probe"));
  std::string outcome;
  ASSERT_TRUE(lines_.WaitForPrefix("probe:", &outcome));

  // Whatever the helper found at that handle value, it was not this event.
  EXPECT_EQ(WaitForSingleObject(bystander, 0),
            static_cast<DWORD>(WAIT_TIMEOUT));

  StopOrDie(CoreProcess::kDefaultShutdownGraceMs);
  CloseHandle(bystander);
}

TEST_F(CoreProcessTest, DropsOutputThatNeverEndsItsLine) {
  ASSERT_TRUE(Start("flood"));
  ASSERT_TRUE(lines_.WaitFor("after"));

  // 300 KB arrived without a newline. Had it been kept, it would be here.
  EXPECT_LT(lines_.LongestLine(), static_cast<size_t>(128 * 1024));

  StopOrDie(CoreProcess::kDefaultShutdownGraceMs);
}

}  // namespace
}  // namespace vless_dart
