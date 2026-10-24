import 'package:flutter/material.dart';

import 'tokens.dart';

/// 页面切换只淡入当前这一层。
///
/// 默认的 [AnimatedSwitcher] 会把新旧两个子组件叠在一起。页面是透明的时候，
/// 液态玻璃会把底下那一页和渐变一起采样进去，看起来就是两层界面叠着显示。
class MotionSwitch extends StatelessWidget {
  final Widget child;
  final Duration duration;
  const MotionSwitch({super.key, required this.child, this.duration = Motion.short4});

  @override
  Widget build(BuildContext context) {
    final bg = Theme.of(context).colorScheme.surface;
    return AnimatedSwitcher(
      duration: duration,
      switchInCurve: MotionCurves.enter,
      switchOutCurve: MotionCurves.exit,
      layoutBuilder: (current, _) => ColoredBox(color: bg, child: current ?? const SizedBox.shrink()),
      child: child,
    );
  }
}

/// 不透明的淡入路由。不滑动：滑动时透明页面会露出下面那一页。
/// 曲线动画只创建一次，避免在 [PageRouteBuilder.transitionsBuilder] 里每次重建都泄漏。
Route<T> fadeRoute<T>(Widget page, {Duration? duration, Duration? reverse}) => PageRouteBuilder<T>(
      opaque: true,
      pageBuilder: (_, _, _) => page,
      transitionDuration: duration ?? Motion.short4,
      reverseTransitionDuration: reverse ?? Motion.short3,
      transitionsBuilder: (_, animation, _, child) => MotionFade(animation: animation, child: child),
    );

/// 菜单 / 对话框只淡入。不用会超过 1 的弹簧缩放，否则玻璃层会采到被拉变形的背景。
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
      CurvedAnimation(parent: parent, curve: MotionCurves.enter, reverseCurve: MotionCurves.exit);

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
