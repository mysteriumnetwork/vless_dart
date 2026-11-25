#ifndef FLUTTER_PLUGIN_VLESS_DART_SESSION_END_H_
#define FLUTTER_PLUGIN_VLESS_DART_SESSION_END_H_

#include <windows.h>

#include <functional>

namespace vless_dart {

// Tells its owner that the Windows session is ending: a logoff, a restart or
// a shutdown.
//
// Windows ends a session by terminating what is in it, so nothing that would
// run when the app quits runs then. The core is a console process and would
// be told directly, except that Windows stops telling a process once user32
// is loaded into it, and what it asks for instead is this: a hidden window
// that is sent WM_ENDSESSION.
//
// A top-level window, not a message-only one. The message is broadcast to
// top-level windows, and a message-only window is never sent it.
class SessionEndWatcher {
 public:
  using Handler = std::function<void()>;

  // on_end runs on the thread that constructs this, from inside the window
  // procedure, once the session is certain to end. The process can be
  // terminated as soon as it returns, so whatever it does has to be done by
  // then.
  explicit SessionEndWatcher(Handler on_end);
  ~SessionEndWatcher();

  SessionEndWatcher(const SessionEndWatcher&) = delete;
  SessionEndWatcher& operator=(const SessionEndWatcher&) = delete;

  // Null when the window could not be created; nothing is watched then.
  HWND window() const { return window_; }

 private:
  static LRESULT CALLBACK WindowProc(HWND window, UINT message, WPARAM wparam,
                                     LPARAM lparam);

  Handler on_end_;
  HWND window_ = nullptr;
};

}  // namespace vless_dart

#endif  // FLUTTER_PLUGIN_VLESS_DART_SESSION_END_H_
