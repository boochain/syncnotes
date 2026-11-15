import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syncnotes/ui/ds.dart';
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

  test('v0.4 theme: one palette, one 5-step type ramp; contrast >= 4.5:1', () {
    for (final b in Brightness.values) {
      final dark = b == Brightness.dark;
      final m = buildAppTheme(b);
      final c = dark ? AppColors.dark : AppColors.light;
      expect(m.colorScheme.primary, pick(HigColors.blue, dark));
      expect(c.accent, pick(HigColors.blue, dark));
      expect(m.scaffoldBackgroundColor, c.bg);
      expect(m.textTheme.bodyLarge!.fontFamilyFallback, contains('Noto Sans CJK SC'));
      // 所有 Material 文本角色只用字阶里的 5 个字号、3 个字重
      final t = m.textTheme;
      final styles = [t.displayLarge, t.displayMedium, t.displaySmall, t.headlineLarge, t.headlineMedium, t.headlineSmall,
        t.titleLarge, t.titleMedium, t.titleSmall, t.bodyLarge, t.bodyMedium, t.bodySmall, t.labelLarge, t.labelMedium, t.labelSmall];
      final sizes = styles.map((s) => s!.fontSize).toSet();
      final weights = styles.map((s) => s!.fontWeight).toSet();
      expect(sizes.difference({12.0, 14.0, 16.0, 20.0}), isEmpty);
      expect(weights.difference({FontWeight.w400, FontWeight.w500, FontWeight.w600}), isEmpty);
      expect(t.titleLarge!.fontWeight, FontWeight.w600);
      expect(t.titleMedium!.fontWeight, FontWeight.w600);
      expect(m.appBarTheme.toolbarHeight, Sizes.bar);
      final fg = m.colorScheme.onSurface, bg = m.colorScheme.surface;
      final l1 = fg.computeLuminance(), l2 = bg.computeLuminance();
      final hi = l1 > l2 ? l1 : l2, lo = l1 > l2 ? l2 : l1;
      expect((hi + 0.05) / (lo + 0.05), greaterThan(4.5));
      // 次级文字也要达到 4.5:1
      final s2 = c.text2.computeLuminance();
      final h2 = s2 > l2 ? s2 : l2, o2 = s2 > l2 ? l2 : s2;
      expect((h2 + 0.05) / (o2 + 0.05), greaterThan(4.5));
    }
  });

  test('height scale is 28/32/36/44/56 and spacing on a 2pt grid', () {
    expect(Sizes.all, [28, 32, 36, 44, 56]);
    for (final v in [Gap.xs, Gap.s, Gap.m, Gap.l, Gap.xl, Gap.xxl, Gap.x3, Gap.x4]) {
      expect(v % 2, 0);
    }
  });

  test('editor typography follows AppFlowy/Notion proportions', () {
    expect(EditorType.body.size, 16);
    expect(EditorType.body.lineHeight, 24);
    expect(EditorType.h1.size, 30);
    expect(EditorType.h2.size, 24);
    expect(EditorType.h3.size, 20);
    expect(EditorType.pageTitle.size, 36);
    for (final h in [EditorType.pageTitle, EditorType.h1, EditorType.h2, EditorType.h3]) {
      expect(h.weight, FontWeight.w600);
    }
  });
}
