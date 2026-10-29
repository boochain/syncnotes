import 'package:flutter/material.dart';

import 'ds.dart';
import 'theme.dart';
import 'tokens.dart';

/// 浮层材质。只用于菜单、斜杠菜单、快速查找、格式工具栏。
///
/// 不再用折射着色器，也不用 [BackdropFilter]。两者都会把底下的页面再画一遍，
/// 高分屏上看起来就是两层界面叠在一起。打开时只加边和阴影，颜色始终不透明。
class Glass extends StatelessWidget {
  static bool useShader = true;

  /// 液态玻璃主题。测试里关掉。着色器不再使用：高分屏上会把背景再画一遍。
  static final enabled = ValueNotifier<bool>(true);

  final Widget child;
  final double radius;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;

  /// 兼容旧参数；浮层同一外观
  final bool strong;
  const Glass({super.key, required this.child, this.radius = AppRadius.l, this.padding, this.margin, this.strong = true});

  static Color tint(BuildContext context) => AppColors.of(context).elevated;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: enabled,
      builder: (context, on, _) {
        final inner = padding == null ? child : Padding(padding: padding!, child: child);
        final deco = floatingDecoration(context, radius: radius);
        // 不采样背景。着色器和 BackdropFilter 都会把底下的页面再画一遍，
        // 3.5x 的屏幕上看起来就是两层界面叠在一起。开着时只多一层边和阴影。
        final body = DecoratedBox(
          decoration: BoxDecoration(color: tint(context), borderRadius: BorderRadius.circular(radius)),
          child: inner,
        );
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
