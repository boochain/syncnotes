import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import 'ds.dart';
import 'theme.dart';
import 'tokens.dart';

/// 浮层材质（v0.4：只用于浮动的界面元素——菜单、斜杠菜单、快速查找、格式工具栏）。
///
/// 外观统一：elevated 色（94% 不透明）+ 细边 + 阴影。着色器版本使用 liquid_glass_widgets，
/// 只保留很淡的边缘高光，保证文字可读、颜色和其余界面一致；[useShader] 为 false 时用 BackdropFilter。
class Glass extends StatelessWidget {
  static bool useShader = true;

  final Widget child;
  final double radius;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;

  /// 兼容旧参数；v0.4 所有浮层同一外观
  final bool strong;
  const Glass({super.key, required this.child, this.radius = AppRadius.l, this.padding, this.margin, this.strong = true});

  static Color tint(BuildContext context, {bool strong = true}) => AppColors.of(context).elevated.withValues(alpha: 0.94);

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final inner = padding == null ? child : Padding(padding: padding!, child: child);
    final deco = floatingDecoration(context, radius: radius);
    Widget body;
    if (useShader) {
      body = GlassContainer(
        useOwnLayer: true,
        clipBehavior: Clip.antiAlias,
        shape: LiquidRoundedSuperellipse(borderRadius: radius),
        settings: LiquidGlassSettings(
          glassColor: tint(context),
          blur: Materials.blurContent,
          thickness: 12,
          saturation: 1.0,
          lightIntensity: dark ? 0.15 : 0.25,
          chromaticAberration: 0,
        ),
        child: inner,
      );
    } else {
      body = ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: Materials.blurContent, sigmaY: Materials.blurContent),
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
  }
}

/// v0.4：背景是纯色（不再有彩色流动渐变）。保留类名以免改动调用处。
class GlassBackdrop extends StatelessWidget {
  final Widget child;
  const GlassBackdrop({super.key, required this.child});
  @override
  Widget build(BuildContext context) => ColoredBox(color: AppColors.of(context).bg, child: child);
}

/// [HIG] 弹簧，用于菜单 / 快速切换器出现。
final springCurve = SpringCurve(Springs.smooth);
