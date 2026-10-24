import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

  /// tray_manager 只会在「可执行文件旁边的 data/flutter_assets」里找图标。
  static String bundledAssetPath(String executable, String asset, {String? separator}) {
    final sep = separator ?? Platform.pathSeparator;
    final cut = executable.lastIndexOf(sep);
    final dir = cut < 0 ? '.' : executable.substring(0, cut);
    return '$dir${sep}data${sep}flutter_assets$sep${asset.replaceAll('/', sep)}';
  }

  static String get _trayAsset => Platform.isWindows ? 'assets/tray_icon.ico' : 'assets/tray_icon.png';

  /// Windows 的 LoadImage 读不了 PNG 压缩的 ico。图标必须是按尺寸展开的 BMP，
  /// 并且包含 16/20/24/32/40/48/64，高缩放比才找得到对应的小图标。
  static Future<bool> _ensureTrayIcon() async {
    final file = File(bundledAssetPath(Platform.resolvedExecutable, _trayAsset));
    try {
      if (await file.exists() && await file.length() > 0) return true;
      final data = await rootBundle.load(_trayAsset);
      await file.parent.create(recursive: true);
      await file.writeAsBytes(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes), flush: true);
      return await file.exists();
    } catch (e) {
      debugPrint('tray icon file: $e');
      return false;
    }
  }

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

  /// 把想要的窗口（逻辑像素）限制在这块显示器里。
  ///
  /// [physical] 是 [Display.size]，单位是物理像素。只除一次 [devicePixelRatio]。
  /// Windows 上 window_manager 的 setSize 会再乘视图的缩放比，这里不能除第二次，
  /// 否则 200% 缩放的窗口会缩成四分之一。
  static Size fitWithin(Size want, {required Size physical, required double devicePixelRatio}) {
    final scale = devicePixelRatio <= 0 ? 1.0 : devicePixelRatio;
    final maxW = physical.width / scale - 48;
    final maxH = physical.height / scale - 80;
    final width = want.width <= maxW ? want.width : (maxW < minimumSize.width ? minimumSize.width : maxW);
    final height = want.height <= maxH ? want.height : (maxH < minimumSize.height ? minimumSize.height : maxH);
    return Size(width, height);
  }

  /// 比屏幕大的窗口缩进可见区域，避免标题栏跑到屏幕外面。
  static Size fitToDisplay(Size want) {
    final displays = WidgetsBinding.instance.platformDispatcher.displays;
    if (displays.isEmpty) return want;
    final d = displays.first;
    final views = WidgetsBinding.instance.platformDispatcher.views;
    final viewScale = views.isEmpty ? 0.0 : views.first.devicePixelRatio;
    final scale = d.devicePixelRatio > 0 ? d.devicePixelRatio : (viewScale > 0 ? viewScale : 1.0);
    return fitWithin(want, physical: d.size, devicePixelRatio: scale);
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
      if (!await _ensureTrayIcon()) throw StateError('tray icon file missing');
      await trayManager.setIcon(_trayAsset);
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
    final next = fitToDisplay(expanded.value ? expandedSize : windowSize);
    if (expanded.value) {
      await windowManager.setSize(next);
      await windowManager.center();
    } else {
      await windowManager.setSize(next);
      await windowManager.setAlignment(Alignment.bottomRight);
    }
  }

  static Future<bool> isAutoStartEnabled() => AutoStart.isEnabled();
  static Future<bool> setAutoStart(bool v) => AutoStart.setEnabled(v);

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
