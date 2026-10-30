import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import 'ds.dart';
import 'theme.dart';
import 'tokens.dart';

/// 浮层材质。菜单、斜杠菜单、快速查找、格式工具栏，以及侧边栏。
///
/// 页面内容保持够不透明，切换时不会叠出上一页。
/// 2.5x 及以上不再做折射（折射会把同一页再画一遍），但仍走玻璃着色器的模糊和边缘高光。
class Glass extends StatelessWidget {
  static bool useShader = true;

  /// 液态玻璃开关。测试里关掉，避免动画停不下来。
  static final enabled = ValueNotifier<bool>(true);

  /// 浮层不透明度。页面本身始终不透明。
  static final opacity = ValueNotifier<double>(0.55);

  /// default / sea / dusk / paper / ink
  static final preset = ValueNotifier<String>('default');

  /// 折射只在较低缩放比上打开。3.5x 上折射会复制出第二层画面。
  static bool refractsAt(double dpr) => dpr > 0 && dpr < 2.5;

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
        final bend = refractsAt(dpr);
        final Widget body;
        if (useShader && on) {
          final dark = Theme.of(context).brightness == Brightness.dark;
          body = GlassContainer(
            useOwnLayer: true,
            quality: GlassQuality.standard,
            clipBehavior: Clip.antiAlias,
            shape: LiquidRoundedSuperellipse(borderRadius: radius),
            settings: LiquidGlassSettings(
              glassColor: tint(context, frosted: true, alpha: alpha),
              blur: bend ? 10 : 16,
              thickness: bend ? 6 : 0,
              refractiveIndex: bend ? 1.04 : 1.0,
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

/// 窗口底色。玻璃打开时是一层能透出来的色晕，否则是纯色。
class GlassBackdrop extends StatelessWidget {
  final Widget child;
  const GlassBackdrop({super.key, required this.child});

  static Color? washFor(String preset) {
    const washes = {
      'sea': Color(0xFF2F6FDB),
      'dusk': Color(0xFF6B4C9A),
      'paper': Color(0xFFC4A574),
      'ink': Color(0xFF111111),
    };
    return washes[preset];
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: Glass.enabled,
      builder: (context, on, _) {
        final base = AppColors.of(context).bg;
        if (!on) return ColoredBox(color: base, child: child);
        return ValueListenableBuilder<String>(
          valueListenable: Glass.preset,
          builder: (context, name, _) {
            final wash = washFor(name) ?? AppColors.of(context).accent;
            return DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    Color.lerp(base, wash, 0.62)!,
                    Color.lerp(base, wash, 0.22)!,
                    base,
                  ],
                ),
              ),
              child: child,
            );
          },
        );
      },
    );
  }
}

/// 侧边栏 / 抽屉。玻璃打开时模糊背后的色晕；关掉时就是原来的纯色块。
class Frosted extends StatelessWidget {
  final Widget child;
  final Color color;
  final BoxBorder? border;
  const Frosted({super.key, required this.child, required this.color, this.border});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: Glass.enabled,
      builder: (context, on, _) {
        if (!on) {
          return DecoratedBox(decoration: BoxDecoration(color: color, border: border), child: child);
        }
        return ValueListenableBuilder<double>(
          valueListenable: Glass.opacity,
          builder: (context, alpha, _) => ClipRect(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
              child: DecoratedBox(
                decoration: BoxDecoration(color: color.withValues(alpha: alpha), border: border),
                child: child,
              ),
            ),
          ),
        );
      },
    );
  }
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
