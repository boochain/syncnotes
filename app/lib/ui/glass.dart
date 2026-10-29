import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import 'ds.dart';
import 'theme.dart';
import 'tokens.dart';

/// 浮层材质。只用于菜单、斜杠菜单、快速查找、格式工具栏。
///
/// 页面本身保持不透明，这里才采样背后那一层。高分屏上折射着色器会把同一页再画一遍，
/// 所以 2.5x 及以上只用模糊，不再折射。
class Glass extends StatelessWidget {
  static bool useShader = true;

  /// 液态玻璃开关。测试里关掉，避免动画停不下来。
  static final enabled = ValueNotifier<bool>(true);

  /// 浮层不透明度。页面本身始终不透明。
  static final opacity = ValueNotifier<double>(0.55);

  /// default / sea / dusk / paper / ink
  static final preset = ValueNotifier<String>('default');

  final Widget child;
  final double radius;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;

  /// 兼容旧参数；浮层同一外观
  final bool strong;
  const Glass({super.key, required this.child, this.radius = AppRadius.l, this.padding, this.margin, this.strong = true});

  static Color tint(BuildContext context, {required bool frosted, double alpha = 0.55}) {
    final base = AppColors.of(context).elevated;
    if (!frosted) return base;
    return base.withValues(alpha: alpha);
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: enabled,
      builder: (context, on, _) => ValueListenableBuilder<double>(
        valueListenable: opacity,
        builder: (context, alpha, _) {
        final inner = padding == null ? child : Padding(padding: padding!, child: child);
        final deco = floatingDecoration(context, radius: radius);
        final dpr = MediaQuery.devicePixelRatioOf(context);
        // 3.5x 上折射会把背景再画一层。那种屏幕只模糊，不折射。
        final refract = useShader && on && dpr < 2.5;
        final Widget body;
        if (refract) {
          final dark = Theme.of(context).brightness == Brightness.dark;
          body = GlassContainer(
            useOwnLayer: true,
            quality: GlassQuality.standard,
            clipBehavior: Clip.antiAlias,
            shape: LiquidRoundedSuperellipse(borderRadius: radius),
            settings: LiquidGlassSettings(
              glassColor: tint(context, frosted: true, alpha: alpha),
              blur: 10,
              thickness: 6,
              refractiveIndex: 1.04,
              saturation: 1.05,
              lightIntensity: dark ? 0.22 : 0.32,
              glowIntensity: 0.14,
              chromaticAberration: 0,
              bodyMode: GlassBodyMode.clear,
            ),
            child: inner,
          );
        } else if (on) {
          body = ClipRRect(
            borderRadius: BorderRadius.circular(radius),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
              child: ColoredBox(color: tint(context, frosted: true, alpha: alpha), child: inner),
            ),
          );
        } else {
          body = DecoratedBox(
            decoration: BoxDecoration(color: tint(context, frosted: false), borderRadius: BorderRadius.circular(radius)),
            child: inner,
          );
        }
        return Padding(
          padding: margin ?? EdgeInsets.zero,
          child: DecoratedBox(
            position: DecorationPosition.foreground,
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(radius), border: on ? deco.border : null),
            child: DecoratedBox(
              decoration: BoxDecoration(borderRadius: BorderRadius.circular(radius), boxShadow: on ? deco.boxShadow : const []),
              child: body,
            ),
          ),
        );
      },
      ),
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
