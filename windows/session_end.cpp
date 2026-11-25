#include "session_end.h"

#include <utility>

namespace vless_dart {

namespace {

constexpr wchar_t kWindowClass[] = L"VlessDartSessionEnd";

}  // namespace

SessionEndWatcher::SessionEndWatcher(Handler on_end)
    : on_end_(std::move(on_end)) {
  WNDCLASSEXW window_class = {};
  window_class.cbSize = sizeof(window_class);
  window_class.lpfnWndProc = WindowProc;
  window_class.hInstance = GetModuleHandleW(nullptr);
  window_class.lpszClassName = kWindowClass;
  // A repeat registration fails with ERROR_CLASS_ALREADY_EXISTS, which is the
  // expected result for a second engine in the same process and not a fault.
  RegisterClassExW(&window_class);

  // Never shown, and a tool window so it stays out of the taskbar and the
  // window switcher even if something shows it. No parent: that is what
  // makes it top-level.
  window_ = CreateWindowExW(WS_EX_TOOLWINDOW, kWindowClass, nullptr, WS_POPUP,
                            0, 0, 0, 0, nullptr, nullptr,
                            window_class.hInstance, this);
  if (window_ == nullptr) {
    OutputDebugStringA(
        "vless_dart: no session-end window; a shutdown with a tunnel up is "
        "not cleaned up after\n");
  }
}

SessionEndWatcher::~SessionEndWatcher() {
  if (window_ != nullptr) {
    DestroyWindow(window_);
    window_ = nullptr;
  }
}

LRESULT CALLBACK SessionEndWatcher::WindowProc(HWND window, UINT message,
                                               WPARAM wparam, LPARAM lparam) {
  if (message == WM_NCCREATE) {
    auto* create = reinterpret_cast<CREATESTRUCTW*>(lparam);
    SetWindowLongPtrW(window, GWLP_USERDATA,
                      reinterpret_cast<LONG_PTR>(create->lpCreateParams));
    return DefWindowProcW(window, message, wparam, lparam);
  }

  // WM_QUERYENDSESSION is left to the default, which agrees. It is only a
  // question: any other app may still refuse, and the session then carries
  // on. WM_ENDSESSION says how it went, and only a true one is an ending.
  if (message == WM_ENDSESSION && wparam != FALSE) {
    auto* self = reinterpret_cast<SessionEndWatcher*>(
        GetWindowLongPtrW(window, GWLP_USERDATA));
    if (self != nullptr && self->on_end_) {
      self->on_end_();
    }
    return 0;
  }
  return DefWindowProcW(window, message, wparam, lparam);
}

}  // namespace vless_dart
