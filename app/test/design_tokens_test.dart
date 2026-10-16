import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syncnotes/ui/theme.dart';
import 'package:syncnotes/ui/tokens.dart';

void main() {
  test('tokens match published spec values', () {
    // [M3] type scale
    expect(M3Type.bodyLarge.size, 16);
    expect(M3Type.bodyLarge.lineHeight, 24);
    expect(M3Type.titleLarge.size, 22);
    // [Fluent] type ramp
    expect(FluentType.body1.size, 14);
    expect(FluentType.subtitle1.lineHeight, 28);
    // [HIG] system blue & Dynamic Type body
    expect(HigColors.blue.$1, const Color(0xFF007AFF));
    expect(HigColors.blue.$2, const Color(0xFF0A84FF));
    expect(HigType.body.size, 17);
    // [M3] motion
    expect(Motion.medium2.inMilliseconds, 300);
    expect(MotionCurves.emphasizedDecelerate, const Cubic(0.05, 0.7, 0.1, 1.0));
    // [M3] shape / [Fluent] radius
    expect(Radii.extraLarge, 28);
    expect(Radii.fluentMedium, 4);
    // 4 点网格
    for (final v in [Space.xs, Space.s, Space.m, Space.l, Space.xxl, Space.xxxl]) {
      expect(v % 4, 0);
    }
  });

  test('HIG spring converts and settles at 1', () {
    final c = SpringCurve(Springs.smooth);
    expect(c.transform(1.0), 1.0);
    expect(c.transform(0.5), greaterThan(0.8));
    // response 0.55 → stiffness (2π/0.55)²
    expect(Springs.smooth.stiffness, closeTo(130.5, 0.5));
  });

  test('HIG-based theme on every platform; body contrast >= 4.5:1', () {
    for (final b in Brightness.values) {
      final dark = b == Brightness.dark;
      final m = buildAppTheme(b);
      // 测试运行在 Linux 主机 → 桌面字阶（Dynamic Type Small，正文 15）
      expect(m.textTheme.bodyLarge!.fontSize, isDesktopPlatform ? 15 : 17);
      expect(m.colorScheme.primary, pick(HigColors.blue, dark));
      expect(m.textTheme.bodyLarge!.fontFamilyFallback, contains('Noto Sans CJK SC'));
      final fg = m.colorScheme.onSurface, bg = m.colorScheme.surface;
      final l1 = fg.computeLuminance(), l2 = bg.computeLuminance();
      final hi = l1 > l2 ? l1 : l2, lo = l1 > l2 ? l2 : l1;
      expect((hi + 0.05) / (lo + 0.05), greaterThan(4.5));
    }
  });

  test('editor typography follows Notion proportions', () {
    expect(EditorType.body.size, 16);
    expect(EditorType.h1.size / EditorType.body.size, closeTo(1.875, 0.01));
    expect(EditorType.h2.size / EditorType.body.size, 1.5);
    expect(EditorType.h3.size / EditorType.body.size, 1.25);
    expect(EditorType.pageTitle.size, 40);
  });
}
