import 'package:flutter/material.dart';

import 'glass.dart';
import 'tokens.dart';

/// 零叠层内容切换器：严格只渲染当前页，彻底杜绝新旧两页同时绘制造成的叠字与重影。
class MotionSwitch extends StatelessWidget {
  final Widget child;
  final Duration duration;
  const MotionSwitch({super.key, required this.child, this.duration = Motion.short4});

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: duration,
      reverseDuration: Duration.zero,
      switchInCurve: Curves.easeOutCubic,
      layoutBuilder: (currentChild, previousChildren) => currentChild ?? const SizedBox.shrink(),
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: SlideTransition(
          position: Tween<Offset>(begin: const Offset(0, 0.012), end: Offset.zero).animate(animation),
          child: child,
        ),
      ),
      child: child,
    );
  }
}

/// 零叠层 Apple 风格页面转场：
/// 一旦上层路由推入（`secondaryAnimation.value > 0`），下层路由立刻 `Offstage` 且暂停 Ticker，
/// 彻底避免液态玻璃透明底色下两层页面叠加、文字穿透重影的问题。
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
    final entering = FadeTransition(
      opacity: curved,
      child: SlideTransition(
        position: Tween<Offset>(begin: const Offset(0.025, 0), end: Offset.zero).animate(curved),
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.992, end: 1.0).animate(curved),
          child: translucent ? child : ColoredBox(color: Theme.of(context).colorScheme.surface, child: child),
        ),
      ),
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
      transitionDuration: duration ?? Motion.short4,
      reverseTransitionDuration: reverse ?? Motion.short3,
      transitionsBuilder: (context, animation, secondaryAnimation, child) {
        final translucent = Glass.surfaceTranslucent;
        final curved = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
          reverseCurve: Curves.easeInCubic,
        );
        final body = FadeTransition(
          opacity: curved,
          child: SlideTransition(
            position: Tween<Offset>(begin: const Offset(0.025, 0), end: Offset.zero).animate(curved),
            child: translucent ? child : ColoredBox(color: Theme.of(context).colorScheme.surface, child: child),
          ),
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

/// 对话框 / 快速切换器出现动画（淡入 + 轻微缩放，Apple HIG 阻尼曲线）。
class MotionFade extends StatelessWidget {
  final Animation<double> animation;
  final Widget child;
  const MotionFade({super.key, required this.animation, required this.child});

  @override
  Widget build(BuildContext context) {
    final c = CurvedAnimation(parent: animation, curve: Curves.easeOutCubic, reverseCurve: Curves.easeInCubic);
    return FadeTransition(
      opacity: c,
      child: ScaleTransition(
        scale: Tween<double>(begin: 0.96, end: 1.0).animate(c),
        child: child,
      ),
    );
  }
}