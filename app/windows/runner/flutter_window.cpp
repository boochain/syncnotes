#include "flutter_window.h"

#include <optional>
#include <string>

#include <shellapi.h>

#include "flutter/generated_plugin_registrant.h"
#include "resource.h"

namespace {
constexpr UINT kWmTray = WM_APP + 21;
constexpr UINT_PTR kTrayTimer = 1;
constexpr UINT kCmdShow = 1;
constexpr UINT kCmdQuit = 2;

std::wstring TipFor(const std::string& text) {
  if (text.empty()) return L"SyncNotes";
  int n = MultiByteToWideChar(CP_UTF8, 0, text.c_str(), -1, nullptr, 0);
  if (n <= 1) return L"SyncNotes";
  std::wstring out(static_cast<size_t>(n - 1), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, text.c_str(), -1, out.data(), n);
  if (out.size() > 127) out.resize(127);
  return out;
}
}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::AddTray(HWND window) {
  HICON icon = static_cast<HICON>(LoadImageW(
      GetModuleHandleW(nullptr), MAKEINTRESOURCEW(IDI_APP_ICON), IMAGE_ICON,
      GetSystemMetrics(SM_CXSMICON), GetSystemMetrics(SM_CYSMICON),
      LR_DEFAULTCOLOR));
  bool owned = icon != nullptr;
  if (!owned) {
    icon = LoadIconW(nullptr, IDI_APPLICATION);
  }
  const bool was = tray_ok_;
  if (icon_owned_ && tray_.hIcon != nullptr && tray_.hIcon != icon) {
    DestroyIcon(tray_.hIcon);
  }
  const HWND old_hwnd = tray_.hWnd != nullptr ? tray_.hWnd : window;
  ZeroMemory(&tray_, sizeof(tray_));
  tray_.cbSize = sizeof(tray_);
  tray_.hWnd = old_hwnd;
  tray_.uID = 1;
  tray_.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
  tray_.uCallbackMessage = kWmTray;
  tray_.hIcon = icon;
  wcscpy_s(tray_.szTip, L"SyncNotes");
  const BOOL ok = Shell_NotifyIconW(was ? NIM_MODIFY : NIM_ADD, &tray_);
  tray_ok_ = ok == TRUE;
  icon_owned_ = tray_ok_ && owned;
  if (!tray_ok_) {
    if (owned && icon != nullptr) DestroyIcon(icon);
    tray_.hIcon = nullptr;
    icon_owned_ = false;
    return false;
  }
  if (!told_user_) {
    told_user_ = true;
    wcscpy_s(tray_.szInfoTitle, L"SyncNotes");
    wcscpy_s(tray_.szInfo, L"已在通知区域。点图标打开窗口，右键可以选择退出。");
    tray_.uFlags |= NIF_INFO;
    tray_.dwInfoFlags = NIIF_INFO;
    Shell_NotifyIconW(NIM_MODIFY, &tray_);
    tray_.uFlags &= ~NIF_INFO;
  }
  return true;
}

void FlutterWindow::RemoveTray() {
  if (tray_.hWnd != nullptr) {
    Shell_NotifyIconW(NIM_DELETE, &tray_);
  }
  if (tray_.hIcon != nullptr && icon_owned_) {
    DestroyIcon(tray_.hIcon);
    tray_.hIcon = nullptr;
  }
  icon_owned_ = false;
  tray_ok_ = false;
}

void FlutterWindow::ShowFromTray(HWND window) {
  if (IsIconic(window)) {
    ShowWindow(window, SW_RESTORE);
  } else {
    ShowWindow(window, SW_SHOW);
  }
  SetForegroundWindow(window);
}

void FlutterWindow::ShowTrayMenu(HWND window) {
  HMENU menu = CreatePopupMenu();
  if (menu == nullptr) return;
  AppendMenuW(menu, MF_STRING, kCmdShow, L"显示窗口");
  AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  AppendMenuW(menu, MF_STRING, kCmdQuit, L"退出");
  POINT pt;
  GetCursorPos(&pt);
  SetForegroundWindow(window);
  TrackPopupMenu(menu, TPM_RIGHTBUTTON | TPM_BOTTOMALIGN, pt.x, pt.y, 0, window, nullptr);
  DestroyMenu(menu);
  PostMessage(window, WM_NULL, 0, 0);
}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

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
          if (tray_ok_) {
            const std::wstring tip = TipFor(text);
            wcsncpy_s(tray_.szTip, tip.c_str(), _TRUNCATE);
            tray_.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
            Shell_NotifyIconW(NIM_MODIFY, &tray_);
          }
          result->Success();
          return;
        }
        if (call.method_name() == "quit") {
          force_quit_ = true;
          close_to_tray_ = false;
          if (hwnd != nullptr) PostMessage(hwnd, WM_CLOSE, 0, 0);
          result->Success();
          return;
        }
        result->NotImplemented();
      });

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
    if (HWND hwnd = GetHandle()) AddTray(hwnd);
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (tray_.hWnd != nullptr) KillTimer(tray_.hWnd, kTrayTimer);
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
  // 在插件之前处理。window_manager 会把关闭吞掉，窗口就关不掉。
  if (message == WM_CLOSE && close_to_tray_ && tray_ok_ && !force_quit_) {
    ShowWindow(hwnd, SW_HIDE);
    return 0;
  }
  if (message == kWmTray) {
    if (lparam == WM_LBUTTONUP || lparam == WM_LBUTTONDBLCLK) {
      ShowFromTray(hwnd);
    } else if (lparam == WM_RBUTTONUP) {
      ShowTrayMenu(hwnd);
    }
    return 0;
  }
  if (message == WM_COMMAND) {
    switch (LOWORD(wparam)) {
      case kCmdShow:
        ShowFromTray(hwnd);
        return 0;
      case kCmdQuit:
        force_quit_ = true;
        close_to_tray_ = false;
        PostMessage(hwnd, WM_CLOSE, 0, 0);
        return 0;
    }
  }
  if (message == WM_TIMER && wparam == kTrayTimer) {
    tray_tries_++;
    if (AddTray(hwnd) || tray_tries_ > 10) KillTimer(hwnd, kTrayTimer);
    return 0;
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