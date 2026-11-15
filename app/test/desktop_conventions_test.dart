import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:syncnotes/platform/desktop.dart';
import 'package:syncnotes/services/settings.dart';

void main() {
  test('window bounds are remembered per mode', () async {
    SharedPreferences.setMockInitialValues({});
    final s = await Settings.load();
    expect(s.windowBounds('compact'), isNull);
    s.setWindowBounds('compact', const Rect.fromLTWH(100, 200, 400, 640));
    s.setWindowBounds('expanded', const Rect.fromLTWH(10, 20, 1120, 740));
    expect(s.windowBounds('compact'), const Rect.fromLTWH(100, 200, 400, 640));
    expect(s.windowBounds('expanded'), const Rect.fromLTWH(10, 20, 1120, 740));
  });

  test('implausible bounds (too small / far off-screen) are ignored', () {
    expect(DesktopShell.plausibleBounds(const Rect.fromLTWH(100, 100, 400, 640)), isTrue);
    expect(DesktopShell.plausibleBounds(const Rect.fromLTWH(100, 100, 100, 100)), isFalse);
    expect(DesktopShell.plausibleBounds(const Rect.fromLTWH(-5000, 100, 400, 640)), isFalse);
  });

  test('close-to-tray defaults on; a normal launch is not hidden', () async {
    SharedPreferences.setMockInitialValues({});
    final s = await Settings.load();
    expect(s.closeToTray, isTrue);
    expect(s.startMinimized, isFalse);
    s.closeToTray = false;
    expect(s.closeToTray, isFalse);
  });

  test('tray icon path sits beside the executable, where tray_manager looks', () {
    expect(
      DesktopShell.bundledAssetPath(r'C:\SyncNotes\syncnotes.exe', 'assets/tray_icon.ico', separator: r'\'),
      r'C:\SyncNotes\data\flutter_assets\assets\tray_icon.ico',
    );
    expect(
      DesktopShell.bundledAssetPath('/opt/SyncNotes/syncnotes', 'assets/tray_icon.png', separator: '/'),
      '/opt/SyncNotes/data/flutter_assets/assets/tray_icon.png',
    );
  });

  test('windows tray icon is a classic bmp ico with high-dpi sizes', () {
    final bytes = File('assets/tray_icon.ico').readAsBytesSync();
    final data = ByteData.sublistView(Uint8List.fromList(bytes));
    expect(data.getUint16(0, Endian.little), 0);
    expect(data.getUint16(2, Endian.little), 1);
    final count = data.getUint16(4, Endian.little);
    final sizes = <int>[];
    for (var i = 0; i < count; i++) {
      final entry = 6 + i * 16;
      sizes.add(data.getUint8(entry));
      final offset = data.getUint32(entry + 12, Endian.little);
      // BITMAPINFOHEADER, not a PNG (LoadImage ignores PNG-compressed ico images).
      expect(data.getUint32(offset, Endian.little), 40);
      expect(bytes[offset], isNot(0x89));
    }
    for (final s in [16, 20, 24, 32, 40, 48, 64]) {
      expect(sizes, contains(s));
    }
  });
}
