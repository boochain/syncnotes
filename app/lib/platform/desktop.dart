import 'dart:io';

import 'package:flutter/material.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'autostart.dart';

bool get isDesktop => !Platform.isAndroid && !Platform.isIOS && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

/// 桌面端：托盘常驻 + 右下角小窗口 + 开机自启。
class DesktopShell with TrayListener, WindowListener {
  static final DesktopShell instance = DesktopShell._();
  DesktopShell._();

  static const Size windowSize = Size(400, 640);
  VoidCallback? onQuit;

  Future<void> init({required bool startHidden}) async {
    await windowManager.ensureInitialized();
    final opts = WindowOptions(
      size: windowSize,
      minimumSize: const Size(340, 420),
      title: 'SyncNotes',
      skipTaskbar: false,
      titleBarStyle: TitleBarStyle.normal,
    );
    await windowManager.waitUntilReadyToShow(opts, () async {
      await windowManager.setAlignment(Alignment.bottomRight);
      if (!startHidden) {
        await windowManager.show();
        await windowManager.focus();
      }
    });
    await windowManager.setPreventClose(true);
    windowManager.addListener(this);

    try {
      await trayManager.setIcon(Platform.isWindows ? 'assets/tray_icon.ico' : 'assets/tray_icon.png');
      if (!Platform.isLinux) await trayManager.setToolTip('SyncNotes');
      await _setMenu(unread: 0);
      trayManager.addListener(this);
    } catch (e) {
      debugPrint('tray unavailable: $e');
      // 没有托盘时保证窗口可见
      await windowManager.show();
    }
  }

  Future<void> _setMenu({required int unread}) async {
    await trayManager.setContextMenu(Menu(items: [
      MenuItem(key: 'show', label: unread > 0 ? '显示窗口（$unread 未读）' : '显示窗口'),
      MenuItem.separator(),
      MenuItem(key: 'quit', label: '退出'),
    ]));
  }

  Future<void> updateUnread(int unread) async {
    try {
      await _setMenu(unread: unread);
      if (!Platform.isLinux) await trayManager.setToolTip(unread > 0 ? 'SyncNotes · $unread 未读' : 'SyncNotes');
    } catch (_) {}
  }

  Future<void> toggle() async {
    if (await windowManager.isVisible() && await windowManager.isFocused()) {
      await windowManager.hide();
    } else {
      await showNearTray();
    }
  }

  Future<void> showNearTray() async {
    await windowManager.setAlignment(Alignment.bottomRight);
    await windowManager.show();
    await windowManager.focus();
  }

  static Future<bool> isAutoStartEnabled() => AutoStart.isEnabled();
  static Future<void> setAutoStart(bool v) => AutoStart.setEnabled(v);

  @override
  void onTrayIconMouseDown() => toggle();

  @override
  void onTrayIconRightMouseDown() => trayManager.popUpContextMenu();

  @override
  void onTrayMenuItemClick(MenuItem menuItem) async {
    switch (menuItem.key) {
      case 'show':
        await showNearTray();
        break;
      case 'quit':
        onQuit?.call();
        await windowManager.setPreventClose(false);
        await trayManager.destroy();
        await windowManager.destroy();
        exit(0);
    }
  }

  /// 点关闭 → 隐藏到托盘
  @override
  void onWindowClose() async {
    await windowManager.hide();
  }
}
