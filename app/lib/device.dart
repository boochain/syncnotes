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
}
