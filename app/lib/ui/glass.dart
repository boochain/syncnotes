import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import 'tokens.dart';

/// Apple 风格 "Liquid Glass" 视觉层。
///
/// 使用开源库 liquid_glass_widgets（着色器折射 + 模糊 + 高光，Windows/Linux/Android 均可用）。
/// 当 [Glass.useShader] 为 false（例如 widget 测试环境）时退回 BackdropFilter 毛玻璃。
class Glass extends StatelessWidget {
  static bool useShader = true;

  final Widget child;
  final double radius;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;

  /// 内容面板（编辑器/列表）使用更高的不透明度以保证可读性
  final bool strong;
  const Glass({super.key, required this.child, this.radius = Radii.glassPanel, this.padding, this.margin, this.strong = false});

  static Color tint(BuildContext context, {bool strong = false}) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return dark
        ? pick(HigColors.secondarySystemBackground, true).withValues(alpha: strong ? Materials.tintContent(true) : Materials.tintRegular(true))
        : Colors.white.withValues(alpha: strong ? Materials.tintContent(false) : Materials.tintRegular(false));
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final inner = padding == null ? child : Padding(padding: padding!, child: child);
    Widget glass;
    if (useShader) {
      glass = GlassContainer(
        useOwnLayer: true,
        clipBehavior: Clip.antiAlias,
        shape: LiquidRoundedSuperellipse(borderRadius: radius),
        settings: LiquidGlassSettings(
          glassColor: tint(context, strong: strong),
          blur: strong ? Materials.blurContent : Materials.blurRegular,
          thickness: 22,
          saturation: 1.7,
          lightIntensity: dark ? 0.35 : 0.6,
          chromaticAberration: 0.015,
        ),
        child: inner,
      );
    } else {
      glass = ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: Materials.blurContent, sigmaY: Materials.blurContent),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: tint(context, strong: strong),
              borderRadius: BorderRadius.circular(radius),
              border: Border.all(color: Colors.white.withValues(alpha: dark ? 0.10 : 0.55)),
            ),
            child: inner,
          ),
        ),
      );
    }
    return Padding(padding: margin ?? EdgeInsets.zero, child: glass);
  }
}

/// 鲜艳的流动渐变背景（玻璃后面需要有内容才能折射）。
class GlassBackdrop extends StatefulWidget {
  final Widget child;
  const GlassBackdrop({super.key, required this.child});
  @override
  State<GlassBackdrop> createState() => _GlassBackdropState();
}

class _GlassBackdropState extends State<GlassBackdrop> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(seconds: 40));

  @override
  void initState() {
    super.initState();
    // 测试与减少动态效果时保持静止
    if (Glass.useShader) _c.repeat();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.maybeDisableAnimationsOf(context) == true) _c.stop();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final base = dark
        ? const [Color(0xFF0B0F2A), Color(0xFF1A0B2E)]
        : const [Color(0xFFEAF2FF), Color(0xFFFFEEF6)];
    final blobs = dark
        // 背景光斑取 [HIG] system colors：blue / purple / teal / pink（浅色模式用 orange 代替 pink 更柔和）
        ? [HigColors.indigo.$2, HigColors.purple.$2, HigColors.teal.$2, HigColors.pink.$2]
        : [HigColors.blue.$1, HigColors.pink.$1, HigColors.teal.$1, HigColors.orange.$1];
    return Stack(fit: StackFit.expand, children: [
      RepaintBoundary(
        child: AnimatedBuilder(
          animation: _c,
          builder: (context, _) => CustomPaint(painter: _BlobPainter(_c.value, base, blobs, dark)),
        ),
      ),
      widget.child,
    ]);
  }
}

class _BlobPainter extends CustomPainter {
  final double t;
  final List<Color> base, blobs;
  final bool dark;
  _BlobPainter(this.t, this.base, this.blobs, this.dark);

  @override
  void paint(Canvas canvas, Size s) {
    final r = Offset.zero & s;
    canvas.drawRect(r, Paint()..shader = LinearGradient(colors: base, begin: Alignment.topLeft, end: Alignment.bottomRight).createShader(r));
    final a = t * 2 * math.pi;
    final pos = [
      Offset(0.15 + 0.10 * math.sin(a), 0.20 + 0.08 * math.cos(a)),
      Offset(0.85 + 0.08 * math.cos(a * 1.3), 0.25 + 0.10 * math.sin(a)),
      Offset(0.30 + 0.12 * math.cos(a), 0.85 + 0.06 * math.sin(a * 0.7)),
      Offset(0.80 + 0.06 * math.sin(a * 0.9), 0.80 + 0.09 * math.cos(a)),
    ];
    final m = math.max(s.width, s.height);
    for (var i = 0; i < blobs.length; i++) {
      final c = Offset(pos[i].dx * s.width, pos[i].dy * s.height);
      final rad = m * (0.42 + 0.06 * i % 0.2);
      canvas.drawCircle(
        c,
        rad,
        Paint()
          ..shader = RadialGradient(colors: [
            blobs[i].withValues(alpha: dark ? 0.50 : 0.42),
            blobs[i].withValues(alpha: 0),
          ]).createShader(Rect.fromCircle(center: c, radius: rad)),
      );
    }
  }

  @override
  bool shouldRepaint(_BlobPainter o) => o.t != t || o.dark != dark;
}

/// [HIG] bouncy 弹簧，用于菜单 / 快速切换器出现。
final springCurve = SpringCurve(Springs.bouncy);
