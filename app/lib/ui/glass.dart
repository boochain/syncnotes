import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import 'ds.dart';
import 'theme.dart';
import 'tokens.dart';

/// 浮层材质。只用于菜单、斜杠菜单、快速查找、格式工具栏。
///
/// 着色器走 [GlassQuality.standard]（轻量片段着色器）。色差和强折射在高分屏上
/// 不会随 devicePixelRatio 缩小，3.5x 的手机会把背景再画一遍，看起来像叠了两层。
class Glass extends StatelessWidget {
  static bool useShader = true;

  /// 液态玻璃主题。测试里关掉，避免金样和纯色断言被背景带着变。
  static final enabled = ValueNotifier<bool>(true);

  final Widget child;
  final double radius;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;

  /// 兼容旧参数；浮层同一外观
  final bool strong;
  const Glass({super.key, required this.child, this.radius = AppRadius.l, this.padding, this.margin, this.strong = true});

  static Color tint(BuildContext context) {
    final a = enabled.value ? 0.92 : 0.94;
    return AppColors.of(context).elevated.withValues(alpha: a);
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: enabled,
      builder: (context, on, _) {
        final dark = Theme.of(context).brightness == Brightness.dark;
        final inner = padding == null ? child : Padding(padding: padding!, child: child);
        final deco = floatingDecoration(context, radius: radius);
        Widget body;
        if (useShader && on) {
          final dpr = MediaQuery.devicePixelRatioOf(context);
          final hi = dpr >= 2.5;
          body = GlassContainer(
            useOwnLayer: true,
            quality: GlassQuality.standard,
            clipBehavior: Clip.antiAlias,
            shape: LiquidRoundedSuperellipse(borderRadius: radius),
            settings: LiquidGlassSettings(
              glassColor: tint(context),
              blur: hi ? 4 : 8,
              thickness: hi ? 4 : 8,
              refractiveIndex: 1.02,
              saturation: 1,
              lightIntensity: dark ? 0.15 : 0.22,
              glowIntensity: 0.12,
              chromaticAberration: 0,
              bodyMode: GlassBodyMode.clear,
            ),
            child: inner,
          );
        } else {
          body = ClipRRect(
            borderRadius: BorderRadius.circular(radius),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
              child: ColoredBox(color: tint(context), child: inner),
            ),
          );
        }
        return Padding(
          padding: margin ?? EdgeInsets.zero,
          child: DecoratedBox(
            position: DecorationPosition.foreground,
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(radius), border: deco.border),
            child: DecoratedBox(decoration: BoxDecoration(borderRadius: BorderRadius.circular(radius), boxShadow: deco.boxShadow), child: body),
          ),
        );
      },
    );
  }
}

/// 窗口底色。页面本身不透明，这里只垫一层纯色，避免切换时空一帧。
class GlassBackdrop extends StatelessWidget {
  final Widget child;
  const GlassBackdrop({super.key, required this.child});
  @override
  Widget build(BuildContext context) => ColoredBox(color: AppColors.of(context).bg, child: child);
}

/// 页面保持不透明。透明 Scaffold 会让渐变和上一页透出来，玻璃再采样一次就叠成两层。
ThemeData glassTheme(ThemeData base, bool on) {
  if (!on) return base;
  final bg = base.scaffoldBackgroundColor;
  return base.copyWith(
    scaffoldBackgroundColor: bg,
    appBarTheme: base.appBarTheme.copyWith(backgroundColor: bg, surfaceTintColor: Colors.transparent),
  );
}

/// [HIG] 弹簧，用于菜单 / 快速切换器出现。
final springCurve = SpringCurve(Springs.smooth);
