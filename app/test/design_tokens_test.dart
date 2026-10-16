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

  test('themes: Fluent on Windows, Material elsewhere; contrast of body text', () {
    for (final b in Brightness.values) {
      final m = buildAppTheme(b, language: DesignLanguage.material);
      final f = buildAppTheme(b, language: DesignLanguage.fluent);
      expect(m.textTheme.bodyLarge!.fontSize, 16);
      expect(f.textTheme.bodyLarge!.fontSize, 14);
      expect(m.colorScheme.primary, pick(HigColors.blue, b == Brightness.dark));
      expect(f.colorScheme.primary, pick(FluentColors.brandForeground, b == Brightness.dark));
      expect(m.textTheme.bodyLarge!.fontFamilyFallback, contains('Noto Sans CJK SC'));
      // 正文与内容面板（近似为 surface）的对比度 ≥ 4.5:1（WCAG AA）
      final fg = m.colorScheme.onSurface, bg = m.colorScheme.surface;
      double lum(Color c) => c.computeLuminance();
      final hi = lum(fg) > lum(bg) ? lum(fg) : lum(bg), lo = lum(fg) > lum(bg) ? lum(bg) : lum(fg);
      expect((hi + 0.05) / (lo + 0.05), greaterThan(4.5));
    }
  });
}
