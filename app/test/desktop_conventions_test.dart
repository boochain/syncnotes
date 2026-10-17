import 'dart:ui';

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

  test('close-to-tray defaults on and is configurable', () async {
    SharedPreferences.setMockInitialValues({});
    final s = await Settings.load();
    expect(s.closeToTray, isTrue);
    s.closeToTray = false;
    expect(s.closeToTray, isFalse);
  });
}
