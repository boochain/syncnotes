import 'package:flutter/material.dart';

import 'glass.dart';
import 'tokens.dart';

/// 页面转场套组见 `docs/motion.md`：
/// Material 3 Emphasized 时长/缓动 + iOS 式覆盖推入（不对正文做透明度交叉）。
Widget _buildPageCoverTransition(
  BuildContext context,
  Animation<double> animation,
  Animation<double> secondaryAnimation,
  Widget child, {
  required bool isRoot,
}) {
  final reduce = MediaQuery.disableAnimationsOf(context);
  final glassOn = Glass.useShader && Glass.surfaceTranslucent;
  final surface = Theme.of(context).colorScheme.surface;
  final dark = Theme.of(context).brightness == Brightness.dark;

  final page = RepaintBoundary(
    child: glassOn ? child : ColoredBox(color: surface, child: child),
  );

  if (reduce) return page;

  final incoming = CurvedAnimation(
    parent: animation,
    curve: MotionCurves.emphasizedDecelerate,
    reverseCurve: MotionCurves.emphasized,
  );
  final covered = CurvedAnimation(
    parent: secondaryAnimation,
    curve: MotionCurves.emphasizedAccelerate,
    reverseCurve: MotionCurves.emphasizedDecelerate,
  );

  // 新页：从尾侧整页滑入，不透明度始终为 1，裁切防止字画出边界。
  Widget layer = page;
  if (!isRoot) {
    layer = AnimatedBuilder(
      animation: incoming,
      child: page,
      builder: (context, child) {
        final t = incoming.value.clamp(0.0, 1.0);
        return ClipRect(
          child: FractionalTranslation(
            translation: Offset(1.0 - t, 0),
            child: child,
          ),
        );
      },
    );
  }

  // 旧页（含根路由主页）：向首侧视差 30%，上面压暗。正文保持不透明，避免与新页叠字。
  return AnimatedBuilder(
    animation: covered,
    child: layer,
    builder: (context, child) {
      final s = covered.value.clamp(0.0, 1.0);
      final content = ClipRect(
        child: FractionalTranslation(
          translation: Offset(-0.30 * s, 0),
          child: child,
        ),
      );
      if (s <= 0.0) return content;
      final scrim = (dark ? 0.38 : 0.16) * s;
      return Stack(
        fit: StackFit.expand,
        children: [
          content,
          IgnorePointer(
            child: ColoredBox(color: Colors.black.withValues(alpha: scrim)),
          ),
        ],
      );
    },
  );
}

/// 零叠层内容切换器：只渲染当前子视图，采用套组内的短时进入曲线。
class MotionSwitch extends StatelessWidget {
  final Widget child;
  final Duration duration;
  final double maxBlur;
  const MotionSwitch({
    super.key,
    required this.child,
    this.duration = Motion.short4,
    this.maxBlur = 0.0,
  });

  @override
  Widget build(BuildContext context) {
    final reduce = MediaQuery.disableAnimationsOf(context);
    if (reduce) return child;
    return AnimatedSwitcher(
      duration: duration,
      reverseDuration: Duration.zero,
      switchInCurve: MotionCurves.emphasizedDecelerate,
      layoutBuilder: (currentChild, previousChildren) =>
          currentChild ?? const SizedBox.shrink(),
      transitionBuilder: (child, animation) =>
          FadeTransition(opacity: animation, child: child),
      child: child,
    );
  }
}

/// 全局页面路由转场：与 [fadeRoute] 使用同一套覆盖推入。
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
    return _buildPageCoverTransition(
      context,
      animation,
      secondaryAnimation,
      child,
      isRoot: route.isFirst,
    );
  }
}

/// 独立页面路由（笔记编辑器、页面、文件夹、设置等）。
PageRoute<T> fadeRoute<T>(
  Widget page, {
  Duration? duration,
  Duration? reverse,
}) => PageRouteBuilder<T>(
  opaque: true,
  pageBuilder: (ctx, a1, a2) => page,
  transitionDuration: duration ?? Motion.medium4,
  reverseTransitionDuration: reverse ?? Motion.medium2,
  transitionsBuilder: (context, animation, secondaryAnimation, child) =>
      _buildPageCoverTransition(
        context,
        animation,
        secondaryAnimation,
        child,
        isRoot: false,
      ),
);

/// 对话框 / 快速切换器：浮层允许透明度 + 微缩放，仍使用同一套进入/退出曲线。
class MotionFade extends StatelessWidget {
  final Animation<double> animation;
  final Widget child;
  const MotionFade({super.key, required this.animation, required this.child});

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) return child;
    return AnimatedBuilder(
      animation: animation,
      builder: (context, inner) {
        final raw = animation.value.clamp(0.0, 1.0);
        final reverse = animation.status == AnimationStatus.reverse;
        final v = reverse
            ? 1.0 - MotionCurves.emphasizedAccelerate.transform(1.0 - raw)
            : MotionCurves.emphasizedDecelerate.transform(raw);
        final scale = 0.96 + 0.04 * v;
        return Opacity(
          opacity: v,
          child: Transform.scale(
            scale: scale,
            filterQuality: FilterQuality.none,
            child: inner,
          ),
        );
      },
      child: child,
    );
  }
}
