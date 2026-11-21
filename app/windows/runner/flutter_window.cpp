#include "flutter_window.h"

#include <dwmapi.h>
#include <optional>
#include <string>
#include <vector>

#include <shellapi.h>

#include "flutter/generated_plugin_registrant.h"
#include "resource.h"
#include "utils.h"

#ifndef DWMWA_USE_IMMERSIVE_DARK_MODE
#define DWMWA_USE_IMMERSIVE_DARK_MODE 20
#endif

namespace {
constexpr UINT kWmTray = WM_APP + 21;
constexpr UINT_PTR kTrayTimer = 1;
constexpr UINT_PTR kQuitTimer = 2;
constexpr UINT kCmdShow = 1;
constexpr UINT kCmdHide = 2;
constexpr UINT kCmdQuit = 3;

std::wstring TipFor(const std::string& text) {
  if (text.empty()) return L"SyncNotes";
  int n = MultiByteToWideChar(CP_UTF8, 0, text.c_str(), -1, nullptr, 0);
  if (n <= 1) return L"SyncNotes";
  std::wstring out(static_cast<size_t>(n - 1), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, text.c_str(), -1, out.data(), n);
  if (out.size() > 127) out.resize(127);
  return out;
}

std::wstring FallbackTrayIconPath() {
  wchar_t buf[MAX_PATH] = {0};
  DWORD len = GetModuleFileNameW(nullptr, buf, MAX_PATH);
  if (len == 0 || len >= MAX_PATH) return L"";
  std::wstring p(buf, len);
  const auto slash = p.find_last_of(L"\\/");
  if (slash == std::wstring::npos) return L"";
  return p.substr(0, slash) + L"\\data\\flutter_assets\\assets\\tray_icon.ico";
}

// Opt out of Windows 10/11 EcoQoS background power throttling so that when the
// main window is hidden to the system tray (`SW_HIDE`), the OS does not throttle
// Dart timers or drop background WebSocket heartbeats.
void DisableBackgroundPowerThrottling() {
#if defined(PROCESS_POWER_THROTTLING_CURRENT_VERSION)
  PROCESS_POWER_THROTTLING_STATE state{};
  state.Version = PROCESS_POWER_THROTTLING_CURRENT_VERSION;
  state.ControlMask = PROCESS_POWER_THROTTLING_EXECUTION_SPEED
#if defined(PROCESS_POWER_THROTTLING_IGNORE_TIMER_RESOLUTION)
                      | PROCESS_POWER_THROTTLING_IGNORE_TIMER_RESOLUTION
#endif
      ;
  state.StateMask = 0;
  SetProcessInformation(GetCurrentProcess(), ProcessPowerThrottling, &state,
                        sizeof(state));
#endif
}
}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {
  for (const auto& arg : GetCommandLineArguments()) {
    if (arg == "--hidden") {
      start_hidden_ = true;
      hidden_to_tray_ = true;
      break;
    }
  }
}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::AddTray(HWND window) {
  if (window == nullptr) return false;
  const int cx = GetSystemMetrics(SM_CXSMICON);
  const int cy = GetSystemMetrics(SM_CYSMICON);
  HICON icon = tray_.hIcon;
  bool owned = icon_owned_;
  if (icon == nullptr) {
    icon = static_cast<HICON>(LoadImageW(
        GetModuleHandleW(nullptr), MAKEINTRESOURCEW(IDI_APP_ICON), IMAGE_ICON,
        cx, cy, LR_DEFAULTCOLOR));
    if (icon == nullptr) {
      const std::wstring disk_ico = FallbackTrayIconPath();
      if (!disk_ico.empty()) {
        icon = static_cast<HICON>(LoadImageW(
            nullptr, disk_ico.c_str(), IMAGE_ICON, cx, cy,
            LR_LOADFROMFILE | LR_DEFAULTCOLOR));
      }
    }
    owned = icon != nullptr;
    if (!owned) {
      icon = LoadIconW(nullptr, IDI_APPLICATION);
    }
  }

  const bool was = tray_ok_;
  const HWND target_hwnd = tray_.hWnd != nullptr ? tray_.hWnd : window;
  ZeroMemory(&tray_, sizeof(tray_));
  tray_.cbSize = sizeof(tray_);
  tray_.hWnd = target_hwnd;
  tray_.uID = 1;
  tray_.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
  tray_.uCallbackMessage = kWmTray;
  tray_.hIcon = icon;
  wcsncpy_s(tray_.szTip, tip_text_.c_str(), _TRUNCATE);

  BOOL ok = Shell_NotifyIconW(was ? NIM_MODIFY : NIM_ADD, &tray_);
  if (!ok) {
    // Recover from state mismatch (e.g. Explorer restarted or icon already existed).
    ok = Shell_NotifyIconW(was ? NIM_ADD : NIM_MODIFY, &tray_);
  }
  tray_ok_ = ok == TRUE;
  icon_owned_ = tray_ok_ && owned;
  if (!tray_ok_) {
    if (owned && icon != nullptr) DestroyIcon(icon);
    tray_.hIcon = nullptr;
    icon_owned_ = false;
    return false;
  }
  return true;
}

void FlutterWindow::RemoveTray() {
  if (tray_.hWnd != nullptr && tray_ok_) {
    Shell_NotifyIconW(NIM_DELETE, &tray_);
  }
  if (tray_.hIcon != nullptr && icon_owned_) {
    DestroyIcon(tray_.hIcon);
  }
  tray_.hIcon = nullptr;
  icon_owned_ = false;
  tray_ok_ = false;
}

void FlutterWindow::HideToTray(HWND window) {
  if (window == nullptr) return;
  hidden_to_tray_ = true;
  if (shell_channel_) {
    shell_channel_->InvokeMethod("onWindowHiddenToTray",
                                 std::make_unique<flutter::EncodableValue>());
  }
  ShowWindow(window, SW_HIDE);
  if (tray_ok_ && !told_user_) {
    told_user_ = true;
    wcscpy_s(tray_.szInfoTitle, L"SyncNotes");
    wcscpy_s(tray_.szInfo, L"已在通知区域后台运行。点击托盘图标可打开窗口，右键可退出。");
    tray_.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP | NIF_INFO;
    tray_.dwInfoFlags = NIIF_INFO;
    Shell_NotifyIconW(NIM_MODIFY, &tray_);
    tray_.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
  }
}

void FlutterWindow::ShowFromTray(HWND window) {
  if (window == nullptr) return;
  hidden_to_tray_ = false;
  start_hidden_ = false;
  if (!IsWindowVisible(window)) {
    ShowWindow(window, SW_SHOW);
  }
  if (IsIconic(window)) {
    ShowWindow(window, SW_RESTORE);
  }
  HWND fg = GetForegroundWindow();
  DWORD fg_tid = fg != nullptr ? GetWindowThreadProcessId(fg, nullptr) : 0;
  DWORD cur_tid = GetCurrentThreadId();
  if (fg_tid != 0 && fg_tid != cur_tid) {
    AttachThreadInput(fg_tid, cur_tid, TRUE);
    BringWindowToTop(window);
    SetForegroundWindow(window);
    AttachThreadInput(fg_tid, cur_tid, FALSE);
  } else {
    BringWindowToTop(window);
    SetForegroundWindow(window);
  }
  if (flutter_controller_ && flutter_controller_->view()) {
    HWND child = flutter_controller_->view()->GetNativeWindow();
    if (child != nullptr) {
      RECT rect = GetClientArea();
      MoveWindow(child, rect.left, rect.top, rect.right - rect.left,
                 rect.bottom - rect.top, TRUE);
      SetFocus(child);
    }
    flutter_controller_->ForceRedraw();
  }
  if (shell_channel_) {
    shell_channel_->InvokeMethod("onTrayRestore",
                                 std::make_unique<flutter::EncodableValue>());
  }
}

void FlutterWindow::RequestQuit(HWND window) {
  force_quit_ = true;
  close_to_tray_ = false;
  hidden_to_tray_ = false;
  RemoveTray();
  if (window != nullptr) {
    SetTimer(window, kQuitTimer, 1500, nullptr);
  }
  if (shell_channel_) {
    shell_channel_->InvokeMethod("onTrayQuit",
                                 std::make_unique<flutter::EncodableValue>());
  } else if (window != nullptr) {
    DestroyWindow(window);
  }
}

void FlutterWindow::ShowTrayMenu(HWND window) {
  HMENU menu = CreatePopupMenu();
  if (menu == nullptr) return;
  const std::wstring show_label =
      tip_text_ != L"SyncNotes" ? (L"显示窗口（" + tip_text_ + L"）") : L"显示主窗口";
  AppendMenuW(menu, MF_STRING, kCmdShow, show_label.c_str());
  if (IsWindowVisible(window) && !IsIconic(window)) {
    AppendMenuW(menu, MF_STRING, kCmdHide, L"隐藏到托盘");
  }
  AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  AppendMenuW(menu, MF_STRING, kCmdQuit, L"退出 SyncNotes");
  POINT pt;
  GetCursorPos(&pt);
  SetForegroundWindow(window);
  const UINT cmd = static_cast<UINT>(TrackPopupMenu(
      menu, TPM_RETURNCMD | TPM_NONOTIFY | TPM_RIGHTBUTTON | TPM_BOTTOMALIGN,
      pt.x, pt.y, 0, window, nullptr));
  DestroyMenu(menu);
  PostMessage(window, WM_NULL, 0, 0);
  if (cmd == kCmdShow) {
    ShowFromTray(window);
  } else if (cmd == kCmdHide) {
    HideToTray(window);
  } else if (cmd == kCmdQuit) {
    RequestQuit(window);
  }
}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  DisableBackgroundPowerThrottling();

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  taskbar_created_ = RegisterWindowMessageW(L"TaskbarCreated");
  shell_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "syncnotes/win_shell",
      &flutter::StandardMethodCodec::GetInstance());
  shell_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        const HWND hwnd = GetHandle();
        if (call.method_name() == "startTray") {
          const bool ok = hwnd != nullptr && AddTray(hwnd);
          if (!ok && hwnd != nullptr && tray_tries_ < 10) {
            tray_tries_++;
            SetTimer(hwnd, kTrayTimer, 400, nullptr);
          }
          result->Success(flutter::EncodableValue(ok));
          return;
        }
        if (call.method_name() == "setStartHidden") {
          const auto* raw = call.arguments();
          const auto* args = raw == nullptr ? nullptr : std::get_if<flutter::EncodableMap>(raw);
          if (args != nullptr) {
            const auto it = args->find(flutter::EncodableValue("value"));
            if (it != args->end()) {
              if (const auto* v = std::get_if<bool>(&it->second)) {
                start_hidden_ = *v;
                if (start_hidden_ && tray_ok_ && hwnd != nullptr) {
                  hidden_to_tray_ = true;
                  if (IsWindowVisible(hwnd)) ShowWindow(hwnd, SW_HIDE);
                }
              }
            }
          }
          result->Success();
          return;
        }
        if (call.method_name() == "showFromTray") {
          if (hwnd != nullptr) ShowFromTray(hwnd);
          result->Success();
          return;
        }
        if (call.method_name() == "hideToTray") {
          if (hwnd != nullptr && tray_ok_) HideToTray(hwnd);
          result->Success();
          return;
        }
        if (call.method_name() == "setCloseToTray") {
          const auto* raw = call.arguments();
          const auto* args = raw == nullptr ? nullptr : std::get_if<flutter::EncodableMap>(raw);
          if (args != nullptr) {
            const auto it = args->find(flutter::EncodableValue("value"));
            if (it != args->end()) {
              if (const auto* v = std::get_if<bool>(&it->second)) close_to_tray_ = *v;
            }
          }
          result->Success();
          return;
        }
        if (call.method_name() == "setDarkTitleBar") {
          const auto* raw = call.arguments();
          const auto* args = raw == nullptr ? nullptr : std::get_if<flutter::EncodableMap>(raw);
          if (args != nullptr && hwnd != nullptr) {
            const auto it = args->find(flutter::EncodableValue("dark"));
            if (it != args->end()) {
              if (const auto* v = std::get_if<bool>(&it->second)) {
                BOOL enable_dark = *v ? TRUE : FALSE;
                DwmSetWindowAttribute(hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE,
                                      &enable_dark, sizeof(enable_dark));
              }
            }
          }
          result->Success();
          return;
        }
        if (call.method_name() == "setTip") {
          const auto* raw = call.arguments();
          const auto* args = raw == nullptr ? nullptr : std::get_if<flutter::EncodableMap>(raw);
          std::string text;
          if (args != nullptr) {
            const auto it = args->find(flutter::EncodableValue("text"));
            if (it != args->end()) {
              if (const auto* v = std::get_if<std::string>(&it->second)) text = *v;
            }
          }
          tip_text_ = TipFor(text);
          if (tray_ok_) {
            wcsncpy_s(tray_.szTip, tip_text_.c_str(), _TRUNCATE);
            tray_.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
            if (!Shell_NotifyIconW(NIM_MODIFY, &tray_) && hwnd != nullptr) {
              AddTray(hwnd);
            }
          }
          result->Success();
          return;
        }
        if (call.method_name() == "quit") {
          force_quit_ = true;
          close_to_tray_ = false;
          hidden_to_tray_ = false;
          RemoveTray();
          if (hwnd != nullptr) PostMessage(hwnd, WM_CLOSE, 0, 0);
          result->Success();
          return;
        }
        result->NotImplemented();
      });

  if (HWND hwnd = GetHandle()) {
    AddTray(hwnd);
  }

  flutter_controller_->engine()->SetNextFrameCallback([this]() {
    if (HWND hwnd = GetHandle()) {
      AddTray(hwnd);
      if (!start_hidden_ && !hidden_to_tray_) {
        this->Show();
      }
    }
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (HWND hwnd = GetHandle()) {
    KillTimer(hwnd, kTrayTimer);
    KillTimer(hwnd, kQuitTimer);
  }
  if (tray_.hWnd != nullptr) {
    KillTimer(tray_.hWnd, kTrayTimer);
    KillTimer(tray_.hWnd, kQuitTimer);
  }
  RemoveTray();
  shell_channel_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if (message == WM_QUERYENDSESSION) {
    force_quit_ = true;
    close_to_tray_ = false;
    return TRUE;
  }
  if (message == WM_ENDSESSION && wparam == TRUE) {
    force_quit_ = true;
    close_to_tray_ = false;
    RemoveTray();
    return 0;
  }
  if (message == WM_SYSCOMMAND && (wparam & 0xFFF0) == SC_CLOSE && !force_quit_) {
    if (close_to_tray_ && (tray_ok_ || AddTray(hwnd))) {
      HideToTray(hwnd);
      return 0;
    }
  }
  // 在插件之前处理。window_manager 会把关闭吞掉，窗口就关不掉。
  if (message == WM_CLOSE) {
    if (force_quit_) {
      RemoveTray();
      DestroyWindow(hwnd);
      return 0;
    }
    if (close_to_tray_ && (tray_ok_ || AddTray(hwnd))) {
      HideToTray(hwnd);
      return 0;
    }
  }
  // 当窗口隐藏到系统托盘后台驻留时，拦截 WM_SHOWWINDOW(FALSE) 不传给 Flutter 引擎，
  // 避免 flutter_windows 将 Dart Isolate 置为 paused 状态导致后台 WebSocket 同步停止。
  if (message == WM_SHOWWINDOW && wparam == FALSE && hidden_to_tray_ && !force_quit_) {
    return 0;
  }
  if (message == kWmTray) {
    if (lparam == WM_LBUTTONUP) {
      const ULONGLONG now = GetTickCount64();
      if (now - last_tray_click_ms_ > 250) {
        last_tray_click_ms_ = now;
        const HWND fg = GetForegroundWindow();
        const HWND child = (flutter_controller_ && flutter_controller_->view())
                               ? flutter_controller_->view()->GetNativeWindow()
                               : nullptr;
        if (IsWindowVisible(hwnd) && !IsIconic(hwnd) &&
            (fg == hwnd || (child != nullptr && fg == child))) {
          HideToTray(hwnd);
        } else {
          ShowFromTray(hwnd);
        }
      }
    } else if (lparam == WM_LBUTTONDBLCLK) {
      last_tray_click_ms_ = GetTickCount64();
      ShowFromTray(hwnd);
    } else if (lparam == WM_RBUTTONUP || lparam == WM_CONTEXTMENU) {
      ShowTrayMenu(hwnd);
    }
    return 0;
  }
  if (message == WM_COMMAND) {
    switch (LOWORD(wparam)) {
      case kCmdShow:
        ShowFromTray(hwnd);
        return 0;
      case kCmdHide:
        HideToTray(hwnd);
        return 0;
      case kCmdQuit:
        RequestQuit(hwnd);
        return 0;
    }
  }
  if (message == WM_TIMER) {
    if (wparam == kTrayTimer) {
      tray_tries_++;
      if (AddTray(hwnd) || tray_tries_ > 10) KillTimer(hwnd, kTrayTimer);
      return 0;
    }
    if (wparam == kQuitTimer) {
      KillTimer(hwnd, kQuitTimer);
      RemoveTray();
      DestroyWindow(hwnd);
      return 0;
    }
  }
  if (taskbar_created_ != 0 && message == taskbar_created_) {
    tray_ok_ = false;
    AddTray(hwnd);
    return 0;
  }

  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}