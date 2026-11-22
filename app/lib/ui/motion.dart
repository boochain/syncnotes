import 'dart:ui';

import 'package:flutter/material.dart';

import 'glass.dart';
import 'tokens.dart';

/// 帧模糊包装器：动画过程中使用 `ImageFiltered` 对当前帧做平滑失焦→对焦过渡，
/// 静止帧（`sigma <= 0.05`）或测试模式（`!Glass.useShader`）零开销直出原组件。
Widget _frameBlur({required double sigma, required Widget child}) {
  if (!Glass.useShader || sigma <= 0.05) return child;
  return ImageFiltered(
    imageFilter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma, tileMode: TileMode.decal),
    child: child,
  );
}

/// 零叠层帧模糊内容切换器：严格只渲染当前页，入场时从失焦模糊平滑聚焦清晰，杜绝叠字重影。
class MotionSwitch extends StatelessWidget {
  final Widget child;
  final Duration duration;
  final double maxBlur;
  const MotionSwitch({
    super.key,
    required this.child,
    this.duration = Motion.medium1,
    this.maxBlur = 10.0,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: duration,
      reverseDuration: Duration.zero,
      switchInCurve: Curves.easeOutCubic,
      layoutBuilder: (currentChild, previousChildren) => currentChild ?? const SizedBox.shrink(),
      transitionBuilder: (child, animation) => AnimatedBuilder(
        animation: animation,
        builder: (context, c) {
          final v = animation.value.clamp(0.0, 1.0);
          final sigma = (1.0 - v) * maxBlur;
          final scale = 0.985 + 0.015 * v;
          return Opacity(
            opacity: v,
            child: Transform.scale(
              scale: scale,
              child: _frameBlur(sigma: sigma, child: c!),
            ),
          );
        },
        child: child,
      ),
      child: child,
    );
  }
}

/// 零叠层 Apple 风格帧模糊页面转场：
/// - 新页面入场采用「帧模糊聚焦 + 微缩放 + 轻位移」的丝滑液态过渡；
/// - 一旦上层路由推入（`secondaryAnimation.value > 0`），下层路由立刻 `Offstage` 且暂停 Ticker，
///   彻底避免液态玻璃透明底色下两层页面叠加、文字穿透重影的问题。
class OpaqueFadeTransitionsBuilder extends PageTransitionsBuilder {
  const OpaqueFadeTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final translucent = Glass.surfaceTranslucent;
    final curved = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    final entering = AnimatedBuilder(
      animation: curved,
      builder: (context, c) {
        final v = curved.value.clamp(0.0, 1.0);
        final sigma = (1.0 - v) * 12.0;
        final scale = 0.982 + 0.018 * v;
        final dx = (1.0 - v) * 14.0;
        return Opacity(
          opacity: v,
          child: Transform.translate(
            offset: Offset(dx, 0),
            child: Transform.scale(
              scale: scale,
              child: _frameBlur(sigma: sigma, child: c!),
            ),
          ),
        );
      },
      child: translucent ? child : ColoredBox(color: Theme.of(context).colorScheme.surface, child: child),
    );
    return AnimatedBuilder(
      animation: secondaryAnimation,
      builder: (context, c) {
        final covered = secondaryAnimation.value > 0.0;
        return Offstage(
          offstage: covered,
          child: TickerMode(
            enabled: !covered,
            child: c!,
          ),
        );
      },
      child: entering,
    );
  }
}

PageRoute<T> fadeRoute<T>(Widget page, {Duration? duration, Duration? reverse}) => PageRouteBuilder<T>(
      pageBuilder: (ctx, a1, a2) => page,
      transitionDuration: duration ?? Motion.medium1,
      reverseTransitionDuration: reverse ?? Motion.short4,
      transitionsBuilder: (context, animation, secondaryAnimation, child) {
        final translucent = Glass.surfaceTranslucent;
        final curved = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
          reverseCurve: Curves.easeInCubic,
        );
        final body = AnimatedBuilder(
          animation: curved,
          builder: (context, c) {
            final v = curved.value.clamp(0.0, 1.0);
            final sigma = (1.0 - v) * 12.0;
            final scale = 0.982 + 0.018 * v;
            final dx = (1.0 - v) * 14.0;
            return Opacity(
              opacity: v,
              child: Transform.translate(
                offset: Offset(dx, 0),
                child: Transform.scale(
                  scale: scale,
                  child: _frameBlur(sigma: sigma, child: c!),
                ),
              ),
            );
          },
          child: translucent ? child : ColoredBox(color: Theme.of(context).colorScheme.surface, child: child),
        );
        return AnimatedBuilder(
          animation: secondaryAnimation,
          builder: (context, c) {
            final covered = secondaryAnimation.value > 0.0;
            return Offstage(
              offstage: covered,
              child: TickerMode(
                enabled: !covered,
                child: c!,
              ),
            );
          },
          child: body,
        );
      },
    );

/// 对话框 / 快速切换器出现动画（帧模糊聚焦 + 轻微缩放，Apple HIG 阻尼曲线）。
class MotionFade extends StatelessWidget {
  final Animation<double> animation;
  final Widget child;
  const MotionFade({super.key, required this.animation, required this.child});

  @override
  Widget build(BuildContext context) {
    final c = CurvedAnimation(parent: animation, curve: Curves.easeOutCubic, reverseCurve: Curves.easeInCubic);
    return AnimatedBuilder(
      animation: c,
      builder: (context, inner) {
        final v = c.value.clamp(0.0, 1.0);
        final sigma = (1.0 - v) * 8.0;
        final scale = 0.96 + 0.04 * v;
        return Opacity(
          opacity: v,
          child: Transform.scale(
            scale: scale,
            child: _frameBlur(sigma: sigma, child: inner!),
          ),
        );
      },
      child: child,
    );
  }
}