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
  int _unread = 0;
  bool _trayListening = false;
  bool _sizing = false;
  static const _winShell = MethodChannel('syncnotes/win_shell');

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

  /// 展开必须比现在大，收起必须比现在小。两边存成同一个尺寸时，按钮看起来就像坏了。
  static Size sizeForToggle({required bool expand, required Size current, Size? saved}) {
    if (saved != null && saved.width >= minimumSize.width && saved.height >= minimumSize.height) {
      final distinct = expand ? saved.width >= current.width + 48 : saved.width <= current.width - 48;
      if (distinct) return saved;
    }
    return expand ? expandedSize : windowSize;
  }

  @override
  void onWindowResized() {
    if (_sizing) return;
    _saveBounds();
  }

  @override
  void onWindowMoved() {
    if (_sizing) return;
    _saveBounds();
  }

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
        // 先显示一次，让系统把顶层窗口建出来。窗口还藏着的时候注册托盘，
        // Shell_NotifyIcon 会失败，插件却回报成功，于是开关开着但没有图标。
        await windowManager.show();
        if (!hidden) await windowManager.focus();
      });
    } catch (e) {
      debugPrint('window ready: $e');
      try {
        await windowManager.show();
        await windowManager.focus();
      } catch (_) {}
    }
    windowManager.addListener(this);
    final trayOk = await ensureTray();
    if (!trayOk && Platform.isWindows) {
      await Future<void>.delayed(const Duration(milliseconds: 600));
      await ensureTray();
    }
    if (!trayAvailable) {
      // 没有托盘：不能隐藏到托盘，关闭即退出，并且启动时必须显示窗口
      await windowManager.setPreventClose(false);
      if (hidden) {
        hidden = false;
        await windowManager.show();
      }
    } else if (hidden) {
      await windowManager.hide();
    }
    if (Platform.isWindows && (_settings?.autoStart ?? false)) {
      await AutoStart.repairIfNeeded();
    }
  }

  /// 托盘没起来时（例如用户后来才打开「关闭到托盘」）再试一次。
  Future<bool> ensureTray() async {
    if (trayAvailable) return true;
    if (Platform.isWindows) return _ensureWindowsTray();
    try {
      if (!await _ensureTrayIcon()) return false;
      await trayManager.setIcon(_trayAsset);
      if (!Platform.isLinux) {
        await trayManager.setToolTip(_unread > 0 ? 'SyncNotes · $_unread 未读' : 'SyncNotes');
      }
      await _setMenu(unread: _unread);
      if (!_trayListening) {
        trayManager.addListener(this);
        _trayListening = true;
      }
      trayAvailable = true;
      await applyClosePolicy();
      return true;
    } catch (e) {
      debugPrint('tray unavailable: $e');
      trayAvailable = false;
      return false;
    }
  }

  /// Windows 不用 tray_manager。那个插件不管 Shell_NotifyIcon 成不成功都回报成功，
  /// 于是开关开着、图标没有、关闭又被拦住。这里用程序自己的图标，并核对系统是否收下。
  Future<bool> _ensureWindowsTray() async {
    try {
      final ok = await _winShell.invokeMethod<bool>('startTray') ?? false;
      trayAvailable = ok;
      await applyClosePolicy();
      if (ok) await updateUnread(_unread);
      return ok;
    } catch (e) {
      debugPrint('windows tray: $e');
      trayAvailable = false;
      await applyClosePolicy();
      return false;
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
    _unread = unread;
    final tip = unread > 0 ? 'SyncNotes · $unread 未读' : 'SyncNotes';
    if (Platform.isWindows) {
      try {
        await _winShell.invokeMethod<void>('setTip', {'text': tip});
      } catch (_) {}
      return;
    }
    try {
      await _setMenu(unread: unread);
      if (!Platform.isLinux) await trayManager.setToolTip(tip);
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
    if (_sizing) return;
    _sizing = true;
    final want = !expanded.value;
    expanded.value = want;
    _settings?.windowExpanded = want;
    try {
      if (await windowManager.isFullScreen()) await windowManager.setFullScreen(false);
      if (await windowManager.isMaximized()) await windowManager.unmaximize();
      final current = await windowManager.getSize();
      final saved = _settings?.windowBounds(want ? 'expanded' : 'compact');
      final target = fitToDisplay(sizeForToggle(
        expand: want,
        current: current,
        saved: saved == null ? null : Size(saved.width, saved.height),
      ));
      await windowManager.setSize(target);
      if (saved != null && (saved.width - target.width).abs() < 2 && (saved.height - target.height).abs() < 2) {
        await windowManager.setPosition(Offset(saved.left, saved.top));
      } else if (want) {
        await windowManager.center();
      } else {
        await windowManager.setAlignment(Alignment.bottomRight);
      }
    } catch (e) {
      debugPrint('resize window: $e');
    } finally {
      _sizing = false;
      await _saveBounds();
    }
  }

  /// Windows 的关闭在原生代码里处理：托盘在，就藏窗口；托盘不在，就真的退出。
  /// 不再用 window_manager 拦住 WM_CLOSE，那个拦住之后隐藏经常不生效。
  Future<void> applyClosePolicy() async {
    try {
      if (Platform.isWindows) {
        await windowManager.setPreventClose(false);
        await _winShell.invokeMethod<void>('setCloseToTray', {'value': closeHides});
        return;
      }
      await windowManager.setPreventClose(closeHides);
    } catch (e) {
      debugPrint('close policy: $e');
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
    if (Platform.isWindows) {
      try {
        await _winShell.invokeMethod<void>('quit');
      } catch (_) {}
    }
    try {
      await windowManager.setPreventClose(false);
      if (!Platform.isWindows && trayAvailable) await trayManager.destroy();
      await windowManager.destroy();
    } catch (_) {}
    exit(0);
  }

  bool _closing = false;

  /// 点关闭 → 隐藏到托盘（可在设置里改为直接退出）。
  ///
  /// Windows 不走这里：原生窗口过程在插件之前处理 WM_CLOSE。
  /// 其它系统如果藏不住，就退出，不能把窗口留在原地。
  bool get closeHides => trayAvailable && (_settings?.closeToTray ?? true);

  @override
  void onWindowClose() {
    if (Platform.isWindows || _closing) return;
    _closing = true;
    final hide = closeHides;
    Future<void>(() async {
      try {
        await _saveBounds();
        if (!hide) {
          await quit();
          return;
        }
        await windowManager.hide();
        if (await windowManager.isVisible()) await quit();
      } finally {
        _closing = false;
      }
    });
  }
}
