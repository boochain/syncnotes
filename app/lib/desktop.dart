import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

bool get isDesktop => Platform.isWindows || Platform.isLinux || Platform.isMacOS;

class Desk {
  static const Size compact = Size(400, 640);
  static const Size expandedSize = Size(1100, 720);
  static const Size minimum = Size(340, 420);
  static const _channel = MethodChannel('syncnotes/win_shell');
  static bool _sizing = false;

  /// 展开必须比现在大，收起必须比现在小。两边被记成同一个尺寸时，按钮仍然要改大小。
  static Size sizeForToggle({required bool expand, required Size current, Size? saved}) {
    if (saved != null && saved.width >= minimum.width && saved.height >= minimum.height) {
      final distinct = expand ? saved.width >= current.width + 48 : saved.width <= current.width - 48;
      if (distinct) return saved;
    }
    return expand ? expandedSize : compact;
  }

  static Future<void> init({required bool expanded, bool closeToTray = true}) async {
    await windowManager.ensureInitialized();
    const opts = WindowOptions(minimumSize: minimum, title: 'SyncNotes');
    await windowManager.waitUntilReadyToShow(opts, () async {
      await windowManager.setSize(expanded ? expandedSize : compact);
      if (expanded) {
        await windowManager.center();
      } else {
        await windowManager.setAlignment(Alignment.bottomRight);
      }
      await windowManager.show();
      await windowManager.focus();
    });
    if (Platform.isWindows) {
      try {
        await _channel.invokeMethod<bool>('startTray');
        await _channel.invokeMethod<void>('setCloseToTray', {'value': closeToTray});
      } catch (e) {
        debugPrint('tray: $e');
      }
    }
  }

  static Future<void> setCloseToTray(bool value) async {
    if (!Platform.isWindows) return;
    try {
      await _channel.invokeMethod<void>('setCloseToTray', {'value': value});
    } catch (e) {
      debugPrint('tray: $e');
    }
  }

  static Future<void> toggle(bool expand) async {
    if (_sizing) return;
    _sizing = true;
    try {
      if (await windowManager.isFullScreen()) await windowManager.setFullScreen(false);
      if (await windowManager.isMaximized()) await windowManager.unmaximize();
      final current = await windowManager.getSize();
      final target = sizeForToggle(expand: expand, current: current);
      await windowManager.setSize(target);
      if (expand) {
        await windowManager.center();
      } else {
        await windowManager.setAlignment(Alignment.bottomRight);
      }
    } catch (e) {
      debugPrint('resize: $e');
    } finally {
      _sizing = false;
    }
  }

  static Future<void> quit() async {
    if (Platform.isWindows) {
      try {
        await _channel.invokeMethod<void>('quit');
        return;
      } catch (_) {}
    }
    await windowManager.close();
  }
}
