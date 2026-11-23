import 'package:flutter/material.dart';

import 'glass.dart';
import 'tokens.dart';

/// 轻量 GPU 卡片弹出转场：
/// - 根路由（主页）保持透明以展示流体/壁纸背景，不被强制遮盖；
/// - 推入的新页面（笔记编辑器、页面、文件夹、设置、回收站、传输等）作为不透明页面卡片
///   从微缩+轻位移平滑弹出盖住主页，附带柔和暗幕与投影，杜绝透明叠字重影与逐帧模糊卡顿。
Widget _buildPageCardTransition(
  BuildContext context,
  Animation<double> animation,
  Widget child, {
  required bool isRoot,
}) {
  if (isRoot) return child;
  final surface = Theme.of(context).colorScheme.surface;
  final dark = Theme.of(context).brightness == Brightness.dark;
  final opaqueCard = RepaintBoundary(
    child: ColoredBox(color: surface, child: child),
  );
  if (!Glass.useShader) return opaqueCard;

  return AnimatedBuilder(
    animation: animation,
    child: opaqueCard,
    builder: (context, card) {
      final raw = animation.value.clamp(0.0, 1.0);
      final reverse = animation.status == AnimationStatus.reverse;
      final v = reverse ? 1.0 - Curves.easeInCubic.transform(1.0 - raw) : Curves.easeOutCubic.transform(raw);
      if (v >= 0.999) return card!;

      // 仅在极短的首尾边缘平滑收口，其余全程保持 100% 不透明，杜绝页面文字穿透叠加
      final cardOpacity = (v / 0.14).clamp(0.0, 1.0);
      final scale = 0.96 + 0.04 * v;
      final dyFrac = 0.08 * (1.0 - v);
      final radius = 20.0 * (1.0 - v);
      final scrimAlpha = (dark ? 0.38 : 0.16) * v;

      return Stack(
        fit: StackFit.expand,
        children: [
          IgnorePointer(
            child: ColoredBox(color: Colors.black.withValues(alpha: scrimAlpha)),
          ),
          Opacity(
            opacity: cardOpacity,
            child: FractionalTranslation(
              translation: Offset(0, dyFrac),
              child: Transform.scale(
                scale: scale,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(radius),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: (dark ? 0.44 : 0.15) * v),
                        blurRadius: 28,
                        spreadRadius: -2,
                        offset: const Offset(0, 10),
                      ),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(radius),
                    child: card!,
                  ),
                ),
              ),
            ),
          ),
        ],
      );
    },
  );
}

/// 零叠层内容切换器：仅渲染当前子视图，采用纯 GPU 淡入+微缩放，无逐帧模糊开销。
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
    return AnimatedSwitcher(
      duration: duration,
      reverseDuration: Duration.zero,
      switchInCurve: Curves.easeOutCubic,
      layoutBuilder: (currentChild, previousChildren) => currentChild ?? const SizedBox.shrink(),
      transitionBuilder: (child, animation) => AnimatedBuilder(
        animation: animation,
        builder: (context, c) {
          final v = animation.value.clamp(0.0, 1.0);
          final scale = 0.988 + 0.012 * v;
          return Opacity(
            opacity: v,
            child: Transform.scale(scale: scale, child: c),
          );
        },
        child: child,
      ),
      child: child,
    );
  }
}

/// 全局页面路由转场：推入页面作为不透明卡片平滑弹出盖住主页。
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
    return _buildPageCardTransition(context, animation, child, isRoot: route.isFirst);
  }
}

/// 独立页面弹出路由（笔记编辑器、页面、文件夹、设置等）：
/// 以不透明页面卡片弹出覆盖主页，关闭时平滑收回。
PageRoute<T> fadeRoute<T>(Widget page, {Duration? duration, Duration? reverse}) => PageRouteBuilder<T>(
      opaque: true,
      pageBuilder: (ctx, a1, a2) => page,
      transitionDuration: duration ?? const Duration(milliseconds: 240),
      reverseTransitionDuration: reverse ?? const Duration(milliseconds: 190),
      transitionsBuilder: (context, animation, secondaryAnimation, child) =>
          _buildPageCardTransition(context, animation, child, isRoot: false),
    );

/// 对话框 / 快速切换器出现动画（纯 GPU 缩放淡入，零模糊卡顿）。
class MotionFade extends StatelessWidget {
  final Animation<double> animation;
  final Widget child;
  const MotionFade({super.key, required this.animation, required this.child});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: animation,
      builder: (context, inner) {
        final raw = animation.value.clamp(0.0, 1.0);
        final reverse = animation.status == AnimationStatus.reverse;
        final v = reverse ? 1.0 - Curves.easeInCubic.transform(1.0 - raw) : Curves.easeOutCubic.transform(raw);
        final scale = 0.96 + 0.04 * v;
        return Opacity(
          opacity: v,
          child: Transform.scale(scale: scale, child: inner),
        );
      },
      child: child,
    );
  }
}
