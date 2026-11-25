#include "session_end.h"

#include <gtest/gtest.h>
#include <windows.h>

namespace vless_dart {

namespace {

// The messages are sent here the way the system sends them at a logoff or a
// shutdown. That the system does send them to a window like this one is
// Windows's side of it, and only a real session ending shows that.
class SessionEndWatcherTest : public ::testing::Test {
 protected:
  int ended_ = 0;
  SessionEndWatcher watcher_{[this] { ++ended_; }};
};

BOOL CALLBACK FindWindowInThread(HWND window, LPARAM wanted) {
  auto* target = reinterpret_cast<HWND*>(wanted);
  if (window == *target) {
    *target = nullptr;
    return FALSE;
  }
  return TRUE;
}

TEST_F(SessionEndWatcherTest, RunsTheHandlerWhenTheSessionEnds) {
  ASSERT_NE(watcher_.window(), nullptr);

  SendMessageW(watcher_.window(), WM_ENDSESSION, TRUE, 0);

  EXPECT_EQ(ended_, 1);
}

// Sent when some other app refused the shutdown. The session carries on, and
// so must the tunnel.
TEST_F(SessionEndWatcherTest, LeavesACancelledShutdownAlone) {
  ASSERT_NE(watcher_.window(), nullptr);

  SendMessageW(watcher_.window(), WM_ENDSESSION, FALSE, 0);

  EXPECT_EQ(ended_, 0);
}

// Only a question at this point, and one the app must not be the reason for
// answering no to.
TEST_F(SessionEndWatcherTest, AgreesToEndWithoutActingOnTheQuestion) {
  ASSERT_NE(watcher_.window(), nullptr);

  const LRESULT answer =
      SendMessageW(watcher_.window(), WM_QUERYENDSESSION, 0, 0);

  EXPECT_NE(answer, 0);
  EXPECT_EQ(ended_, 0);
}

// The whole reason this is not the plugin's message-only window: the system
// broadcasts the end of a session to top-level windows, and enumeration,
// which walks the same list, never reaches a message-only one.
TEST_F(SessionEndWatcherTest, IsATopLevelWindowNobodySees) {
  ASSERT_NE(watcher_.window(), nullptr);

  HWND remaining = watcher_.window();
  EnumThreadWindows(GetCurrentThreadId(), FindWindowInThread,
                    reinterpret_cast<LPARAM>(&remaining));
  EXPECT_EQ(remaining, nullptr) << "not among the thread's top-level windows";

  EXPECT_FALSE(IsWindowVisible(watcher_.window()));
  EXPECT_NE(GetWindowLongPtrW(watcher_.window(), GWL_EXSTYLE) &
                WS_EX_TOOLWINDOW,
            0);
}

TEST(SessionEndWatcher, StopsWatchingWhenDestroyed) {
  int ended = 0;
  HWND window = nullptr;
  {
    SessionEndWatcher watcher([&ended] { ++ended; });
    window = watcher.window();
    ASSERT_NE(window, nullptr);
  }

  EXPECT_FALSE(IsWindow(window));
  EXPECT_EQ(ended, 0);
}

}  // namespace

}  // namespace vless_dart
