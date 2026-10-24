import 'dart:io';

import 'package:flutter/material.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../services/settings.dart';
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

  Settings? _settings;
  static const Size minimumSize = Size(340, 420);
  String get _mode => expanded.value ? 'expanded' : 'compact';

  /// 保存的位置是否可信（显示器拔掉后不要把窗口放到屏幕外太远）
  static bool plausibleBounds(Rect r) =>
      r.width >= minimumSize.width &&
      r.height >= minimumSize.height &&
      r.width <= 6000 &&
      r.height <= 4000 &&
      r.left > -200 &&
      r.top >= 0 &&
      r.left < 8000 &&
      r.top < 5000 &&
      r.left + r.width > 80;

  /// 比屏幕大的窗口缩进可见区域，避免标题栏跑到屏幕外面。
  static Size fitToDisplay(Size want) {
    final displays = WidgetsBinding.instance.platformDispatcher.displays;
    if (displays.isEmpty) return want;
    final d = displays.first;
    final scale = d.devicePixelRatio == 0 ? 1.0 : d.devicePixelRatio;
    final maxW = d.size.width / scale - 48;
    final maxH = d.size.height / scale - 80;
    final width = want.width <= maxW ? want.width : (maxW < minimumSize.width ? minimumSize.width : maxW);
    final height = want.height <= maxH ? want.height : (maxH < minimumSize.height ? minimumSize.height : maxH);
    return Size(width, height);
  }

  Future<bool> _restoreBounds() async {
    final r = _settings?.windowBounds(_mode);
    if (r == null || !plausibleBounds(r)) return false;
    await windowManager.setBounds(r);
    return true;
  }

  Future<void> _saveBounds() async {
    final s = _settings;
    if (s == null) return;
    try {
      final r = await windowManager.getBounds();
      if (plausibleBounds(r)) s.setWindowBounds(_mode, r);
    } catch (_) {}
  }

  @override
  void onWindowResized() => _saveBounds();
  @override
  void onWindowMoved() => _saveBounds();

  Future<void> init({required bool startHidden, Settings? settings}) async {
    _settings = settings;
    expanded.value = settings?.windowExpanded ?? true;
    var hidden = startHidden;
    await windowManager.ensureInitialized();
    final size = fitToDisplay(expanded.value ? expandedSize : windowSize);
    final opts = WindowOptions(
      size: size,
      minimumSize: minimumSize,
      title: 'SyncNotes',
      skipTaskbar: false,
      titleBarStyle: TitleBarStyle.normal,
    );
    try {
      await windowManager.waitUntilReadyToShow(opts, () async {
        try {
          if (!await _restoreBounds()) {
            await windowManager.setAlignment(expanded.value ? Alignment.center : Alignment.bottomRight);
          }
        } catch (e) {
          debugPrint('place window: $e');
        }
        if (!hidden) {
          await windowManager.show();
          await windowManager.focus();
        }
      });
    } catch (e) {
      debugPrint('window ready: $e');
      try {
        await windowManager.show();
        await windowManager.focus();
      } catch (_) {}
    }
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
    if (!await _restoreBounds()) await windowManager.setAlignment(Alignment.bottomRight);
    await windowManager.show();
    await windowManager.focus();
  }

  /// 在托盘小窗与大窗口（侧边栏 + 页面）之间切换。
  final expanded = ValueNotifier<bool>(false);
  static const Size expandedSize = Size(1120, 740);
  Future<void> toggleExpanded() async {
    expanded.value = !expanded.value;
    _settings?.windowExpanded = expanded.value;
    if (await _restoreBounds()) return;
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

  /// 点关闭 → 隐藏到托盘（可在设置里改为直接退出）
  bool get closeHides => trayAvailable && (_settings?.closeToTray ?? true);

  @override
  void onWindowClose() async {
    await _saveBounds();
    if (closeHides) {
      await windowManager.hide();
    } else {
      await quit();
    }
  }
}
