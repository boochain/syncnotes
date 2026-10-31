import 'dart:io';

import 'package:flutter/services.dart';

class Device {
  static const share = MethodChannel('syncnotes/share');
  static const device = MethodChannel('syncnotes/device');
  static const windows = MethodChannel('syncnotes/win_shell');

  static Future<Map<String, dynamic>?> initialShare() async {
    if (!Platform.isAndroid) return null;
    final raw = await share.invokeMethod<dynamic>('getInitialShare');
    if (raw is Map) return raw.map((k, v) => MapEntry('$k', v));
    return null;
  }

  static Future<String?> initialLink() async {
    if (!Platform.isAndroid) return null;
    return device.invokeMethod<String>('getInitialLink');
  }

  static Future<String?> listen() async {
    if (!Platform.isAndroid) return null;
    return device.invokeMethod<String>('listen');
  }

  static Future<Map<String, dynamic>?> capture() async {
    if (!Platform.isAndroid) return null;
    final raw = await device.invokeMethod<dynamic>('capture');
    if (raw is Map) return raw.map((k, v) => MapEntry('$k', v));
    return null;
  }

  static Future<void> notify(String title, String text) async {
    if (!Platform.isAndroid) return;
    await device.invokeMethod<void>('notify', {'title': title, 'text': text});
  }

  static Future<void> scheduleReminder(int whenMs, String title, String text, int id) async {
    if (!Platform.isAndroid) return;
    await device.invokeMethod<void>('schedule', {'when': whenMs, 'title': title, 'text': text, 'id': id.hashCode});
  }

  /// 剪贴板里的图片。没有就返回空。
  static Future<Uint8List?> clipboardImage() async {
    if (Platform.isWindows) {
      final raw = await windows.invokeMethod<Uint8List>('clipboardImage');
      if (raw != null && raw.isNotEmpty) return raw;
      return null;
    }
    if (Platform.isAndroid) {
      final raw = await device.invokeMethod<Uint8List>('clipboardImage');
      if (raw != null && raw.isNotEmpty) return raw;
      return null;
    }
    if (Platform.isLinux) {
      for (final cmd in [
        ['wl-paste', '-t', 'image/png'],
        ['xclip', '-selection', 'clipboard', '-t', 'image/png', '-o'],
      ]) {
        try {
          final result = await Process.run(cmd.first, cmd.sublist(1), stdoutEncoding: null);
          final out = result.stdout;
          if (result.exitCode == 0 && out is Uint8List && out.length > 8) return out;
        } catch (_) {}
      }
    }
    return null;
  }
}
