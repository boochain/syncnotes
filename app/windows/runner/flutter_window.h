#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <memory>

#include "win32_window.h"

#include <shellapi.h>

// A window that does nothing but host a Flutter view.
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
  void ShowFromTray(HWND window);
  void ShowTrayMenu(HWND window);

  flutter::DartProject project_;
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> shell_channel_;

  NOTIFYICONDATAW tray_{};
  UINT taskbar_created_ = 0;
  bool tray_ok_ = false;
  bool icon_owned_ = false;
  bool told_user_ = false;
  bool close_to_tray_ = true;
  bool force_quit_ = false;
  int tray_tries_ = 0;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
