import 'package:flutter/material.dart';

import 'glass.dart';
import 'tokens.dart';

/// 页面转场套组见 `docs/motion.md`：
/// Material 3 Emphasized 时长/缓动 + iOS 式覆盖推入（不对正文做透明度交叉）。
///
/// v0.8.1：液态玻璃开启时页面本身是透明的（要透出流体背景），新页滑入时旧页的字会从
/// 新页下面透出来（叠字）。现在旧页按新页的左边缘做「遮挡裁切」：新页盖到哪里，旧页
/// 就只画到哪里。两层用同一条曲线、同一个时钟，任何一帧都不会在同一位置同时出现两层字，
/// 也不需要给页面铺实心底色，玻璃与流体背景照样可见。
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

  // 进入与返回严格对称：同一条曲线正放 / 倒放（返回用 emphasized，略快）。
  final incoming = CurvedAnimation(
    parent: animation,
    curve: MotionCurves.emphasizedDecelerate,
    reverseCurve: MotionCurves.emphasized,
  );
  // 被盖住的一层必须与上层「新页」使用完全相同的曲线，才能算出新页左边缘在哪里。
  final covered = CurvedAnimation(
    parent: secondaryAnimation,
    curve: MotionCurves.emphasizedDecelerate,
    reverseCurve: MotionCurves.emphasized,
  );

  // 新页：从尾侧整页滑入，不透明度始终为 1，裁切防止字画出边界。
  Widget layer = page;
  if (!isRoot) {
    layer = AnimatedBuilder(
      animation: incoming,
      child: page,
      builder: (context, child) {
        final t = incoming.value.clamp(0.0, 1.0);
        // 结构保持不变（不在 t==1 时拆掉裁切），否则子树会重建、输入状态丢失。
        return ClipRect(
          child: FractionalTranslation(
            translation: Offset(1.0 - t, 0),
            child: child,
          ),
        );
      },
    );
  }

  // 旧页（含根路由主页）：向首侧视差 30%，并且只画到新页左边缘为止；边缘处一条柔和投影表达 z 轴层级。
  return AnimatedBuilder(
    animation: covered,
    child: layer,
    builder: (context, child) {
      final s = covered.value.clamp(0.0, 1.0);
      // 结构恒定：s==0 时位移 0、裁切全宽、投影透明，不改变子树（保持滚动位置与输入状态）。
      return LayoutBuilder(
        builder: (context, box) {
          final w = box.maxWidth;
          final parallax = -_kParallax * s * w;
          // 新页左边缘（导航器坐标）= (1 - s)·w；旧页自身已左移 parallax。
          final visible = ((1.0 - s) * w - parallax).clamp(0.0, w);
          final shadow = s <= 0.0 ? 0.0 : (dark ? 0.34 : 0.14) * (s < 0.5 ? s * 2 : 1.0);
          return Transform.translate(
            offset: Offset(parallax, 0),
            child: ClipRect(
              clipper: _LeadingClip(visible),
              child: Stack(
                fit: StackFit.passthrough,
                children: [
                  child!,
                  Positioned(
                    top: 0,
                    bottom: 0,
                    left: visible - 18,
                    width: 18,
                    child: IgnorePointer(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [
                              Colors.black.withValues(alpha: 0),
                              Colors.black.withValues(alpha: shadow),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      );
    },
  );
}

/// 被覆盖页的视差比例（iOS push 惯例 30%）。
const _kParallax = 0.30;

class _LeadingClip extends CustomClipper<Rect> {
  final double width;
  const _LeadingClip(this.width);
  @override
  Rect getClip(Size size) => Rect.fromLTWH(0, 0, width.clamp(0.0, size.width), size.height);
  @override
  bool shouldReclip(_LeadingClip old) => old.width != width;
}

/// 页内内容切换器（宽屏收件箱 ⇄ 页面等）：Material 3 Fade-through。
///
/// 旧视图先在前 35% 时间里淡出（加速曲线），新视图在后 65% 里淡入并从 0.96 放大到 1（减速曲线）。
/// 两层的不透明度区间不重叠，所以不会叠字；旧视图也有退出动画，不再「一下子消失 → 闪一下空白」。
class MotionSwitch extends StatelessWidget {
  final Widget child;
  final Duration duration;
  final double maxBlur;
  const MotionSwitch({
    super.key,
    required this.child,
    this.duration = Motion.medium2,
    this.maxBlur = 0.0,
  });

  /// 淡出所占的时间比例（M3 fade-through：outgoing 0–35%，incoming 35–100%）。
  static const fadeOutPortion = 0.35;

  @override
  Widget build(BuildContext context) {
    final reduce = MediaQuery.disableAnimationsOf(context);
    if (reduce) return child;
    return AnimatedSwitcher(
      duration: duration,
      reverseDuration: duration,
      switchInCurve: Curves.linear,
      switchOutCurve: Curves.linear,
      layoutBuilder: (currentChild, previousChildren) => Stack(
        fit: StackFit.passthrough,
        alignment: Alignment.topLeft,
        children: [
          for (final p in previousChildren) IgnorePointer(child: p),
          ?currentChild,
        ],
      ),
      transitionBuilder: (child, animation) =>
          _FadeThrough(animation: animation, child: child),
      child: child,
    );
  }
}

class _FadeThrough extends StatelessWidget {
  final Animation<double> animation;
  final Widget child;
  const _FadeThrough({required this.animation, required this.child});

  static final _in = CurveTween(
    curve: const Interval(MotionSwitch.fadeOutPortion, 1.0, curve: MotionCurves.emphasizedDecelerate),
  );
  static final _out = CurveTween(
    curve: const Interval(1.0 - MotionSwitch.fadeOutPortion, 1.0, curve: MotionCurves.emphasizedAccelerate),
  );

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: animation,
      child: RepaintBoundary(child: child),
      builder: (context, child) {
        final v = animation.value;
        // AnimatedSwitcher：进入的子视图 animation 0→1（forward），离开的 1→0（reverse）。
        final leaving = animation.status == AnimationStatus.reverse;
        final double opacity;
        double scale = 1.0;
        if (leaving) {
          opacity = _out.transform(v);
        } else {
          final t = _in.transform(v);
          opacity = t;
          scale = 0.96 + 0.04 * t;
        }
        return Opacity(
          opacity: opacity.clamp(0.0, 1.0),
          child: Transform.scale(scale: scale, child: child),
        );
      },
    );
  }
}

/// 全局页面路由转场：与 [fadeRoute] 使用同一套覆盖推入。
class OpaqueFadeTransitionsBuilder extends PageTransitionsBuilder {
  const OpaqueFadeTransitionsBuilder();

  /// 进入 400ms（M3 medium4），返回 300ms（M3 medium2）。
  @override
  Duration get transitionDuration => Motion.medium4;

  @override
  Duration get reverseTransitionDuration => Motion.medium2;

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
///
/// v0.8.1：必须是 [MaterialPageRoute]。之前用 `PageRouteBuilder`，而 Material 路由的
/// `canTransitionTo` 只对 `MaterialRouteTransitionMixin` 返回 true —— 结果下层的主页
/// 永远收不到 secondaryAnimation，既不视差、也不被遮挡，透明玻璃页滑进来时两层字叠在一起。
/// 现在所有页面都走主题里的 [OpaqueFadeTransitionsBuilder]，上下两层由同一个时钟驱动。
PageRoute<T> fadeRoute<T>(
  Widget page, {
  Duration? duration,
  Duration? reverse,
}) => MaterialPageRoute<T>(builder: (_) => page);

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

/// 列表项退出动画：被删除 / 移走的一行先淡出并收起高度，再真正从列表里拿掉（与进入的
/// 淡入 + 上移对称）。用法：每次 build 把当前行交给 [merge]，按返回顺序渲染；
/// 离场行用 [CollapseOut] 包好，动画结束后回调 [onSettled] 触发重建。
class ExitTracker {
  List<String> _prev = const [];
  final Map<String, Widget> _lastWidgets = {};
  final Map<String, Widget> _leaving = {};
  static final Set<String> _skip = {};
  Object? _context;

  /// 这一行已经由自己的手势动画移走（例如左滑删除），不要再播一次退出。
  static void skipNext(String id) => _skip.add(id);

  /// [context] 变化（换筛选、换视图）时不播退出动画，直接切换。
  List<(String, Widget)> merge(
    List<(String, Widget)> rows, {
    required Object? context,
    required VoidCallback onSettled,
    int maxBatch = 6,
  }) {
    final ids = [for (final r in rows) r.$1];
    final now = ids.toSet();
    if (!identical(context, _context) && context != _context) {
      _leaving.clear();
    } else {
      final removed = [for (final id in _prev) if (!now.contains(id) && !_leaving.containsKey(id)) id];
      if (removed.length <= maxBatch) {
        for (final id in removed) {
          if (_skip.remove(id)) continue;
          final w = _lastWidgets[id];
          if (w == null) continue;
          _leaving[id] = CollapseOut(
            key: ValueKey('leaving-$id'),
            onDone: () {
              _leaving.remove(id);
              onSettled();
            },
            child: w,
          );
        }
      }
    }
    // 回来的行（例如撤销删除）立刻取消离场。
    _leaving.removeWhere((id, _) => now.contains(id));
    _context = context;

    final out = <(String, Widget)>[...rows];
    if (_leaving.isNotEmpty) {
      // 离场行插在它原来前一个邻居的后面。
      for (final id in _leaving.keys) {
        final at = _prev.indexOf(id);
        var insert = 0;
        for (var i = at - 1; i >= 0; i--) {
          final j = out.indexWhere((r) => r.$1 == _prev[i]);
          if (j >= 0) {
            insert = j + 1;
            break;
          }
        }
        out.insert(insert.clamp(0, out.length), (id, _leaving[id]!));
      }
    }
    _lastWidgets
      ..clear()
      ..addEntries(rows.map((r) => MapEntry(r.$1, r.$2)));
    _prev = [for (final r in out) r.$1];
    return out;
  }
}

/// 退出：淡出 + 高度收起（M3 emphasized-accelerate，[Motion.medium1]）。
class CollapseOut extends StatefulWidget {
  final Widget child;
  final VoidCallback onDone;
  const CollapseOut({super.key, required this.child, required this.onDone});
  @override
  State<CollapseOut> createState() => _CollapseOutState();
}

class _CollapseOutState extends State<CollapseOut> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: Motion.medium1,
    value: 1,
  );
  late final Animation<double> _fade = CurvedAnimation(
    parent: _c,
    curve: const Interval(0.4, 1.0, curve: MotionCurves.emphasizedAccelerate),
  );
  late final Animation<double> _size = CurvedAnimation(parent: _c, curve: MotionCurves.emphasized);

  @override
  void initState() {
    super.initState();
    _c.reverse().whenComplete(() {
      if (mounted) widget.onDone();
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) return const SizedBox.shrink();
    return IgnorePointer(
      child: SizeTransition(
        sizeFactor: _size,
        alignment: Alignment.topCenter,
        child: FadeTransition(opacity: _fade, child: widget.child),
      ),
    );
  }
}
