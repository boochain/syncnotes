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

  /// 退出前调用（例如把本地缓存写完）。
  Future<void> Function()? onQuit;

  /// 托盘是否可用；不可用时点关闭直接退出，否则窗口隐藏后就再也找不回来了。
  bool trayAvailable = false;

  Future<void> init({required bool startHidden}) async {
    var hidden = startHidden;
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
      if (!hidden) {
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
      trayAvailable = true;
    } catch (e) {
      debugPrint('tray unavailable: $e');
      trayAvailable = false;
    }
    if (!trayAvailable) {
      // 没有托盘：不能隐藏到托盘，关闭即退出，并且启动时必须显示窗口
      await windowManager.setPreventClose(false);
      if (hidden) {
        hidden = false;
        await windowManager.show();
      }
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

  /// 在托盘小窗与大窗口（侧边栏 + 页面）之间切换。
  final expanded = ValueNotifier<bool>(false);
  static const Size expandedSize = Size(1120, 740);
  Future<void> toggleExpanded() async {
    expanded.value = !expanded.value;
    if (expanded.value) {
      await windowManager.setSize(expandedSize);
      await windowManager.center();
    } else {
      await windowManager.setSize(windowSize);
      await windowManager.setAlignment(Alignment.bottomRight);
    }
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
        await quit();
    }
  }

  Future<void> quit() async {
    try {
      await onQuit?.call().timeout(const Duration(seconds: 3));
    } catch (_) {}
    await windowManager.setPreventClose(false);
    if (trayAvailable) await trayManager.destroy();
    await windowManager.destroy();
    exit(0);
  }

  /// 点关闭 → 隐藏到托盘
  @override
  void onWindowClose() async {
    if (trayAvailable) {
      await windowManager.hide();
    } else {
      await quit();
    }
  }
}
