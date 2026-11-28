import 'dart:ui' show ImageFilter;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'glass.dart';
import 'tokens.dart';

/// 页面转场套组见 `docs/motion.md`。
///
/// v0.8.2「卡片式弹出页」：所有盖在当前页之上的页面（笔记、页面、任务详情、日历编辑、
/// 设置及子页、备份与同步、回收站……）都是一张**不透明圆角卡片**，四周留边距，边距里
/// 只露出流动背景（[BackdropCover]），**永远不露出下层界面的文字**。
///
/// 动画分两段，区间不重叠，进出完全对称（返回就是同一条时间轴倒放）：
///   0.00–0.35  背景层淡入，把下层页面整个盖住（下层文字在这段里淡出）
///   0.35–1.00  卡片淡入（0.35–0.65）、从下方 24px 上移并从 0.96 放大到 1（emphasizedDecelerate）
/// 卡片出现时背景层已经完全不透明，所以任何一帧都不会有下层文字和卡片内容叠在一起。
/// 背景层淡入的同时，下层页面从第一帧起就被高斯模糊到不可读（[CoverLayer]），
/// 所以淡出过程中的任何一帧也读不到下层文字。
/// 返回：卡片先淡出缩小，背景层再淡出露出下层页面。
const kCardBackdropEnd = 0.35;
const kCardFadeEnd = 0.65;

/// 卡片外边距：手机接近全屏但保留 8dp 边距和圆角；桌面 / 宽屏四周 24，内容最宽 960 居中（Notion peek）。
EdgeInsets cardMarginFor(MediaQueryData mq) {
  final w = mq.size.width;
  if (w < 600) {
    return EdgeInsets.fromLTRB(8, mq.padding.top + 8, 8, mq.padding.bottom + 8);
  }
  final side = ((w - 960) / 2).clamp(24.0, double.infinity);
  return EdgeInsets.fromLTRB(side, mq.padding.top + 24, side, mq.padding.bottom + 24);
}

double cardRadiusFor(MediaQueryData mq) => mq.size.width < 600 ? 16 : 20;

/// 卡片表面：完全不透明（alpha = 1），细描边 + 柔和投影表现高度。
class CardSurface extends StatelessWidget {
  final Widget child;
  final double radius;
  const CardSurface({super.key, required this.child, required this.radius});

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final surface = dark ? const Color(0xFF1C1C1E) : const Color(0xFFFFFFFF);
    final r = BorderRadius.circular(radius);
    return DecoratedBox(
      key: const Key('cardSurface'),
      decoration: BoxDecoration(
        color: surface,
        borderRadius: r,
        border: Border.all(color: dark ? const Color(0x33FFFFFF) : const Color(0x1F000000)),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: dark ? 0.45 : 0.16), blurRadius: 32, offset: const Offset(0, 12)),
        ],
      ),
      child: ClipRRect(
        borderRadius: r,
        // Material 而不是 ColoredBox：卡片里的 ListTile / InkWell 水波纹画在卡片表面上
        child: Material(color: surface, child: child),
      ),
    );
  }
}

/// 盖住下层页面的一层：t>0 的第一帧起就把下层模糊到不可读（σ=20，不过渡），
/// 再用不透明的流动背景淡入盖住。t=0 / t=1 时不做模糊（静止时零开销）。
class CoverLayer extends StatelessWidget {
  final double t;
  final Key? coverKey;
  const CoverLayer({super.key, required this.t, this.coverKey});

  static double sigmaFor(double t) => t <= 0 || t >= 1 ? 0 : 20;

  @override
  Widget build(BuildContext context) {
    final sigma = sigmaFor(t);
    return IgnorePointer(
      child: Stack(fit: StackFit.expand, children: [
        BackdropFilter(
          key: const Key('coverBlur'),
          enabled: sigma > 0,
          filter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma, tileMode: TileMode.clamp),
          child: const SizedBox.expand(),
        ),
        Opacity(key: coverKey, opacity: t.clamp(0.0, 1.0), child: const BackdropCover()),
      ]),
    );
  }
}

Widget _buildCardTransition(
  BuildContext context,
  Animation<double> animation,
  Widget child, {
  required bool isRoot,
}) {
  final popups = PopupCover.maybeFor(context);
  Widget withPopupCover(Widget page) {
    if (popups == null) return page;
    // 对话框、底部弹层、菜单打开时，盖住本页（只露背景图），弹层卡片在它上面。
    return Stack(fit: StackFit.passthrough, children: [
      page,
      Positioned.fill(
        child: AnimatedBuilder(
          animation: popups,
          builder: (context, _) {
            final v = popups.value;
            if (v <= 0) return const SizedBox.shrink();
            return CoverLayer(t: v, coverKey: const Key('popupCover'));
          },
        ),
      ),
    ]);
  }

  if (isRoot) return withPopupCover(child);

  final mq = MediaQuery.of(context);
  final margin = cardMarginFor(mq);
  final radius = cardRadiusFor(mq);
  final reduce = MediaQuery.disableAnimationsOf(context);

  final cover = reduce
      ? kAlwaysCompleteAnimation
      : CurvedAnimation(
          parent: animation,
          curve: const Interval(0, kCardBackdropEnd, curve: Curves.easeOut),
          reverseCurve: const Interval(0, kCardBackdropEnd, curve: Curves.easeIn),
        );
  final fade = reduce
      ? kAlwaysCompleteAnimation
      : CurvedAnimation(
          parent: animation,
          curve: const Interval(kCardBackdropEnd, kCardFadeEnd, curve: Curves.easeOut),
          reverseCurve: const Interval(kCardBackdropEnd, kCardFadeEnd, curve: Curves.easeIn),
        );
  final move = reduce
      ? kAlwaysCompleteAnimation
      : CurvedAnimation(
          parent: animation,
          curve: const Interval(kCardBackdropEnd, 1, curve: Easing.emphasizedDecelerate),
          reverseCurve: const Interval(kCardBackdropEnd, 1, curve: Easing.emphasizedAccelerate),
        );

  // 卡片内部的页面不再自己处理状态栏 / 刘海：卡片已经让开了。
  final inner = MediaQuery(
    data: mq.removePadding(removeTop: true, removeBottom: true, removeLeft: true, removeRight: true).copyWith(
          size: Size(mq.size.width - margin.horizontal, mq.size.height - margin.vertical),
        ),
    child: child,
  );

  // 结构始终不变（不在动画结束时增删包装层），避免页面状态被重建。
  return withPopupCover(Stack(
    fit: StackFit.expand,
    children: [
      AnimatedBuilder(
        animation: cover,
        builder: (context, _) => CoverLayer(t: cover.value, coverKey: const Key('cardBackdrop')),
      ),
      Padding(
        padding: margin,
        child: AnimatedBuilder(
          animation: move,
          builder: (context, card) => Transform.translate(
            offset: Offset(0, 24 * (1 - move.value)),
            child: Transform.scale(scale: 0.96 + 0.04 * move.value, child: card),
          ),
          child: FadeTransition(
            opacity: fade,
            child: RepaintBoundary(child: CardSurface(radius: radius, child: inner)),
          ),
        ),
      ),
    ],
  ));
}

/// 弹层（对话框、底部弹层、菜单、日期选择器……）打开时，下层页面要被背景图盖住。
/// 每个 Navigator 挂一个 [PopupCoverObserver]；它记下本 Navigator 上所有 [PopupRoute] 的动画，
/// 本 Navigator 里的页面用 [PopupCover.value]（取最大值）画一层背景图。弹层的进入 / 退出
/// 动画直接驱动这一层，所以遮盖与弹层同步、进出对称。
class PopupCover extends ChangeNotifier implements ValueListenable<double> {
  static final Expando<PopupCover> _byNavigator = Expando('PopupCover');
  final List<Animation<double>> _anims = [];

  static PopupCover? maybeFor(BuildContext context) {
    final nav = Navigator.maybeOf(context);
    return nav == null ? null : _byNavigator[nav];
  }

  @override
  double get value {
    var v = 0.0;
    for (final a in _anims) {
      // 遮盖比弹层自身先到位：弹层动画前 30% 内背景层就完全不透明（模糊从第一帧开始）
      final t = Curves.easeOut.transform((a.value / 0.3).clamp(0.0, 1.0));
      if (t > v) v = t;
    }
    return v;
  }

  void _add(Animation<double> a) {
    if (_anims.contains(a)) return;
    _anims.add(a);
    a.addListener(notifyListeners);
    void status(AnimationStatus s) {
      if (s == AnimationStatus.dismissed) {
        a.removeListener(notifyListeners);
        a.removeStatusListener(status);
        _anims.remove(a);
        notifyListeners();
      }
    }

    a.addStatusListener(status);
    notifyListeners();
  }
}

/// 底部弹层也是卡片：四周留 8dp、全圆角、不透明，挂在根 Navigator 上（下层整页被背景盖住）。
/// 进入从底部滑入、退出滑回底部（Material 默认，成对）。
Future<T?> showCardSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool isScrollControlled = false,
  bool showDragHandle = true,
  BoxConstraints? constraints,
}) {
  return showModalBottomSheet<T>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: isScrollControlled,
    backgroundColor: Colors.transparent,
    elevation: 0,
    showDragHandle: false,
    constraints: constraints ?? const BoxConstraints(maxWidth: 560),
    builder: (ctx) {
      final mq = MediaQuery.of(ctx);
      final dark = Theme.of(ctx).brightness == Brightness.dark;
      return Padding(
        key: const Key('cardSheet'),
        padding: EdgeInsets.fromLTRB(8, 8, 8, 8 + mq.padding.bottom),
        child: CardSurface(
          radius: 16,
          child: MediaQuery.removePadding(
            context: ctx,
            removeBottom: true,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (showDragHandle)
                Center(
                  child: Container(
                    margin: const EdgeInsets.symmetric(vertical: 8),
                    width: 36,
                    height: 5,
                    decoration: BoxDecoration(
                      color: dark ? const Color(0x66FFFFFF) : const Color(0x4D000000),
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                ),
              Flexible(child: builder(ctx)),
            ]),
          ),
        ),
      );
    },
  );
}

class PopupCoverObserver extends NavigatorObserver {
  final cover = PopupCover();

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    final nav = navigator;
    if (nav != null) PopupCover._byNavigator[nav] = cover;
    if (route is PopupRoute && route.animation != null) cover._add(route.animation!);
  }
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
        // 离开的视图淡出时同时模糊到不可读，避免中间帧还能读到旧内容
        final blur = leaving && opacity < 1 ? 16.0 : 0.0;
        return Opacity(
          opacity: opacity.clamp(0.0, 1.0),
          child: ImageFiltered(
            enabled: blur > 0,
            imageFilter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
            child: Transform.scale(scale: scale, child: child),
          ),
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
    return _buildCardTransition(context, animation, child, isRoot: route.isFirst);
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
