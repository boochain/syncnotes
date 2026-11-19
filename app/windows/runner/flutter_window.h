#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <memory>
#include <string>

#include "win32_window.h"

#include <shellapi.h>

// A window that hosts a Flutter view and manages the native Windows system tray.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  bool AddTray(HWND window);
  void RemoveTray();
  void HideToTray(HWND window);
  void ShowFromTray(HWND window);
  void ShowTrayMenu(HWND window);
  void RequestQuit(HWND window);

  flutter::DartProject project_;
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> shell_channel_;

  NOTIFYICONDATAW tray_{};
  std::wstring tip_text_ = L"SyncNotes";
  UINT taskbar_created_ = 0;
  bool tray_ok_ = false;
  bool icon_owned_ = false;
  bool told_user_ = false;
  bool close_to_tray_ = true;
  bool start_hidden_ = false;
  bool hidden_to_tray_ = false;
  bool force_quit_ = false;
  int tray_tries_ = 0;
  ULONGLONG last_tray_click_ms_ = 0;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
