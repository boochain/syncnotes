import 'package:flutter/material.dart';

import 'tokens.dart';

/// 一次只放当前这一页。
///
/// [AnimatedSwitcher] 默认把新旧两页叠在一起。页面或玻璃层透明时，底下那一页会透上来。
/// 这里丢掉上一页，只在不透明底色上淡入当前页。
class MotionSwitch extends StatelessWidget {
  final Widget child;
  final Duration duration;
  const MotionSwitch({super.key, required this.child, this.duration = Motion.short4});

  @override
  Widget build(BuildContext context) {
    final bg = Theme.of(context).colorScheme.surface;
    return AnimatedSwitcher(
      duration: duration,
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      layoutBuilder: (current, _) => ColoredBox(color: bg, child: current ?? const SizedBox.shrink()),
      transitionBuilder: (child, animation) => FadeTransition(opacity: animation, child: child),
      child: child,
    );
  }
}

/// 不透明淡入。路由从第一帧就盖住上一页，不再用 Cupertino / 预测返回那种滑动，
/// 那些动画会把两页同时画出来。
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
    final bg = Theme.of(context).colorScheme.surface;
    return ColoredBox(
      color: bg,
      child: FadeTransition(
        opacity: animation.drive(CurveTween(curve: Curves.easeOutCubic)),
        child: child,
      ),
    );
  }
}

/// 不透明的淡入路由。曲线动画只创建一次，避免在 transitionsBuilder 里每次重建都泄漏。
Route<T> fadeRoute<T>(Widget page, {Duration? duration, Duration? reverse}) => PageRouteBuilder<T>(
      opaque: true,
      pageBuilder: (_, _, _) => page,
      transitionDuration: duration ?? Motion.short4,
      reverseTransitionDuration: reverse ?? Motion.short3,
      transitionsBuilder: (context, animation, _, child) {
        final bg = Theme.of(context).colorScheme.surface;
        return ColoredBox(color: bg, child: MotionFade(animation: animation, child: child));
      },
    );

/// 菜单 / 对话框只淡入。不用会超过 1 的弹簧缩放，否则会拉出变形的第二层。
class MotionFade extends StatefulWidget {
  final Animation<double> animation;
  final Widget child;
  const MotionFade({super.key, required this.animation, required this.child});

  @override
  State<MotionFade> createState() => _MotionFadeState();
}

class _MotionFadeState extends State<MotionFade> {
  late CurvedAnimation _opacity = _curve(widget.animation);

  CurvedAnimation _curve(Animation<double> parent) =>
      CurvedAnimation(parent: parent, curve: Curves.easeOutCubic, reverseCurve: Curves.easeInCubic);

  @override
  void didUpdateWidget(MotionFade old) {
    super.didUpdateWidget(old);
    if (old.animation != widget.animation) {
      _opacity.dispose();
      _opacity = _curve(widget.animation);
    }
  }

  @override
  void dispose() {
    _opacity.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(opacity: _opacity, child: widget.child);
}