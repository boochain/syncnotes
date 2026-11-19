import 'package:flutter/material.dart';

import 'glass.dart';
import 'tokens.dart';

/// 一次只放当前这一页。
///
/// [AnimatedSwitcher] 默认把新旧两页叠在一起。页面或玻璃层透明时，底下那一页会透上来。
/// 这里丢掉上一页，只在不透明底色（或开启液态玻璃/自定义壁纸时的透明层）上淡入当前页。
class MotionSwitch extends StatelessWidget {
  final Widget child;
  final Duration duration;
  const MotionSwitch({super.key, required this.child, this.duration = Motion.short4});

  @override
  Widget build(BuildContext context) {
    final bg = Glass.surfaceTranslucent ? Colors.transparent : Theme.of(context).colorScheme.surface;
    return AnimatedSwitcher(
      duration: duration,
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      layoutBuilder: (current, _) => ColoredBox(color: bg, child: current ?? const SizedBox.shrink()),
      transitionBuilder: (child, animation) {
        final slide = Tween<Offset>(begin: const Offset(0, 0.03), end: Offset.zero).animate(animation);
        return FadeTransition(opacity: animation, child: SlideTransition(position: slide, child: child));
      },
      child: child,
    );
  }
}

/// 不透明淡入。路由从第一帧就盖住上一页，不再用 Cupertino / 预测返回那种滑动，
/// 那些动画会把两页同时画出来。开启液态玻璃或自定义背景图时隐藏被覆盖的下层路由，让底层壁纸透上来且不叠字。
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
    final bg = translucent ? Colors.transparent : Theme.of(context).colorScheme.surface;
    final curved = animation.drive(CurveTween(curve: Curves.easeOutCubic));
    final body = ColoredBox(
      color: bg,
      child: FadeTransition(
        opacity: curved,
        child: SlideTransition(
          position: Tween<Offset>(begin: const Offset(0, 0.04), end: Offset.zero).animate(curved),
          child: child,
        ),
      ),
    );
    if (!translucent) return body;
    return AnimatedBuilder(
      animation: secondaryAnimation,
      builder: (context, c) => Offstage(
        offstage: secondaryAnimation.value > 0.01,
        child: c,
      ),
      child: body,
    );
  }
}

/// 不透明的淡入路由。曲线动画只创建一次，避免在 transitionsBuilder 里每次重建都泄漏。
Route<T> fadeRoute<T>(Widget page, {Duration? duration, Duration? reverse}) => PageRouteBuilder<T>(
      opaque: true,
      pageBuilder: (_, _, _) => page,
      transitionDuration: duration ?? Motion.short4,
      reverseTransitionDuration: reverse ?? Motion.short3,
      transitionsBuilder: (context, animation, secondaryAnimation, child) {
        final translucent = Glass.surfaceTranslucent;
        final bg = translucent ? Colors.transparent : Theme.of(context).colorScheme.surface;
        final body = ColoredBox(color: bg, child: MotionFade(animation: animation, child: child));
        if (!translucent) return body;
        return AnimatedBuilder(
          animation: secondaryAnimation,
          builder: (context, c) => Offstage(
            offstage: secondaryAnimation.value > 0.01,
            child: c,
          ),
          child: body,
        );
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