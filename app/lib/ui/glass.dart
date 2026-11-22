import 'dart:io';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import 'ds.dart';
import 'motion.dart';
import 'theme.dart';
import 'tokens.dart';

/// 浮层与导航栏材质（基于 `liquid_glass_widgets` + Fresnel 双层镜面高光与色散折射边缘实现 Apple Liquid Glass）。
///
/// 实时响应 `opacity`（玻璃透光与模糊强度）、`refraction`（折射厚度、镜面高光光斑与色散虹彩边）、
/// `quality`（minimal / standard / premium 三档光学质感）以及 `fluidBg`（流体动态背景）。
class Glass extends StatelessWidget {
  static bool useShader = true;

  /// 液态玻璃总开关。测试里默认关闭，避免着色器动画阻塞 pumpAndSettle。
  static final enabled = ValueNotifier<bool>(true);

  /// 流体动态背景开关。默认开启，在真实运行时驱动柔和的流体极光网格。
  static final fluidBg = ValueNotifier<bool>(true);

  /// 浮层不透明度（0.22 – 0.88，默认 0.42 让流体光晕与折射层次清晰可见）。
  static final opacity = ValueNotifier<double>(0.42);

  /// 折射率（1.00 – 1.12，默认 1.06）。
  static final refraction = ValueNotifier<double>(1.06);

  /// 着色器质量档位：standard（全平台轻量 2D 着色器）/ premium（高阶双层色散折射高光）/ minimal（轻薄纯毛玻璃）
  static final quality = ValueNotifier<String>('standard');

  /// 背景色调预设：default / sea / dusk / paper / ink
  static final preset = ValueNotifier<String>('default');

  /// 自定义背景图片路径（支持本地 PNG / JPG / WebP 壁纸）。
  static final bgImage = ValueNotifier<String?>(null);

  /// 自定义背景图片之上的可读性遮罩浓度（0.00 – 0.88，默认 0.35）。
  static final bgDim = ValueNotifier<double>(0.35);

  /// 合并监听所有液态玻璃光学参数与背景变化。
  static Listenable get backdropListenable =>
      Listenable.merge([enabled, fluidBg, preset, bgImage, bgDim, opacity, refraction, quality]);

  /// 是否设置了有效的自定义背景图片。
  static bool get hasCustomBg {
    final p = bgImage.value;
    return p != null && p.isNotEmpty;
  }

  /// 真实运行时且开启液态玻璃或自定义背景图时，允许内层 Scaffold 透出底层 GlassBackdrop 流体光场/壁纸。
  static bool get surfaceTranslucent => useShader && (enabled.value || hasCustomBg);

  /// 内层页面 Scaffold 背景色：开启液态玻璃或壁纸时透明（由 GlassBackdrop 统一绘制），测试或关闭时保持主题底色。
  static Color? scaffoldBg(BuildContext context) => surfaceTranslucent ? Colors.transparent : null;

  /// 折射只在较低缩放比上打开。3.5x 上折射会复制出第二层画面。
  static bool refractsAt(double dpr) => dpr > 0 && dpr < 2.5;

  static GlassQuality resolveQuality(String q) => switch (q) {
        'premium' => GlassQuality.premium,
        _ => GlassQuality.standard,
      };

  /// 折射滑块归一化强度 0.0 – 1.0，供所有液态玻璃表面实时联动光学参数。
  static double refractionStrength(double ior, String qName) {
    final base = ((ior - 1.0) / 0.12).clamp(0.0, 1.0);
    return switch (qName) {
      'minimal' => base * 0.25,
      'premium' => (base * 1.25 + 0.18).clamp(0.0, 1.0),
      _ => base,
    };
  }

  /// 动态模糊半径：随质量档位和透明度联动，保证肉眼清晰分辨。
  static double blurSigmaFor(double alpha, String qName) {
    final base = switch (qName) {
      'minimal' => 14.0,
      'premium' => 30.0,
      _ => 22.0,
    };
    return (base + (1.0 - alpha) * 8.0).clamp(12.0, 36.0);
  }

  final Widget child;
  final double radius;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;

  /// 兼容旧参数；浮层同一外观
  final bool strong;
  const Glass({
    super.key,
    required this.child,
    this.radius = AppRadius.l,
    this.padding,
    this.margin,
    this.strong = true,
  });

  static Color tint(BuildContext context, {required bool frosted, double alpha = 0.42}) {
    final base = AppColors.of(context).elevated;
    if (!frosted) return base;
    return base.withValues(alpha: alpha);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([enabled, opacity, refraction, quality]),
      builder: (context, _) {
        final on = enabled.value;
        final alpha = opacity.value;
        final ior = refraction.value;
        final qName = quality.value;
        final inner = padding == null ? child : Padding(padding: padding!, child: child);
        final deco = floatingDecoration(context, radius: radius);
        final dpr = MediaQuery.devicePixelRatioOf(context);
        final bend = refractsAt(dpr);
        final dark = Theme.of(context).brightness == Brightness.dark;
        final q = resolveQuality(qName);
        final rStr = refractionStrength(ior, qName);
        final blur = blurSigmaFor(alpha, qName);
        final shaderActive = useShader && on && qName != 'minimal' && radius > 0;

        final Widget body;
        if (shaderActive) {
          body = GlassContainer(
            useOwnLayer: true,
            quality: q,
            clipBehavior: Clip.antiAlias,
            shape: LiquidRoundedSuperellipse(borderRadius: radius),
            settings: LiquidGlassSettings(
              glassColor: tint(context, frosted: true, alpha: (alpha * (dark ? 0.56 : 0.68)).clamp(0.14, 0.72)),
              blur: blur,
              thickness: bend ? (14.0 + rStr * 22.0) : 0,
              refractiveIndex: bend ? ior : 1.0,
              saturation: (dark ? 1.32 : 1.24) + rStr * 0.34,
              lightIntensity: (dark ? 0.56 : 0.70) + rStr * 0.30,
              glowIntensity: (dark ? 0.30 : 0.26) + rStr * 0.34,
              chromaticAberration: bend ? (0.02 + rStr * 0.085) : 0,
              bodyMode: GlassBodyMode.clear,
            ),
            child: CustomPaint(
              foregroundPainter: _LiquidRimPainter(
                radius: radius,
                dark: dark,
                strength: rStr,
                premium: qName == 'premium',
                glintBias: 0.62,
              ),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      Colors.white.withValues(alpha: (dark ? 0.14 : 0.50) + rStr * (dark ? 0.10 : 0.18)),
                      Colors.transparent,
                      Colors.white.withValues(alpha: (dark ? 0.05 : 0.14) + rStr * 0.06),
                    ],
                    stops: const [0.0, 0.48, 1.0],
                  ),
                ),
                child: inner,
              ),
            ),
          );
        } else if (on) {
          body = ClipRRect(
            borderRadius: BorderRadius.circular(radius),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
              child: CustomPaint(
                foregroundPainter: _LiquidRimPainter(
                  radius: radius,
                  dark: dark,
                  strength: rStr,
                  premium: false,
                  glintBias: 0.62,
                ),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        Color.alphaBlend(
                          Colors.white.withValues(alpha: dark ? 0.12 : 0.48),
                          tint(context, frosted: true, alpha: alpha),
                        ),
                        tint(context, frosted: true, alpha: (alpha + 0.06).clamp(0.18, 0.84)),
                      ],
                    ),
                  ),
                  child: inner,
                ),
              ),
            ),
          );
        } else {
          body = DecoratedBox(
            decoration: BoxDecoration(color: tint(context, frosted: false), borderRadius: BorderRadius.circular(radius)),
            child: inner,
          );
        }

        return Padding(
          padding: margin ?? EdgeInsets.zero,
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(radius),
              boxShadow: on ? deco.boxShadow : const [],
            ),
            child: body,
          ),
        );
      },
    );
  }
}

/// Fresnel 液态玻璃折射线 + 标志性顶部镜面聚焦光斑（还原 Apple macOS Tahoe & iOS 26 概念图质感）。
class _LiquidRimPainter extends CustomPainter {
  final double radius;
  final bool dark;
  final double strength;
  final bool premium;
  final Color? accent;
  final double glintBias;

  const _LiquidRimPainter({
    required this.radius,
    required this.dark,
    required this.strength,
    required this.premium,
    this.accent,
    this.glintBias = 0.68,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final rect = Offset.zero & size;
    final rrect = RRect.fromRectAndRadius(rect.deflate(0.7), Radius.circular(radius));

    // 1. 主 Fresnel 液态高光描边（左上/右上明亮折光 → 中段通透 → 底部柔和回光）
    final topAlpha = ((dark ? 0.40 : 0.90) + strength * (dark ? 0.36 : 0.10)).clamp(0.0, 1.0);
    final midAlpha = ((dark ? 0.10 : 0.28) + strength * 0.12).clamp(0.0, 1.0);
    final botAlpha = ((dark ? 0.24 : 0.62) + strength * 0.22).clamp(0.0, 1.0);

    final rimPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.15 + strength * 0.42
      ..shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          Colors.white.withValues(alpha: topAlpha),
          (accent ?? Colors.white).withValues(alpha: midAlpha),
          Colors.white.withValues(alpha: botAlpha),
        ],
        stops: const [0.0, 0.50, 1.0],
      ).createShader(rect);
    canvas.drawRRect(rrect, rimPaint);

    // 2. 色散棱镜内边（随折射滑块与 premium 档位增强）
    if (strength > 0.10 || premium) {
      final chromaAlpha = (strength * (premium ? 0.44 : 0.26)).clamp(0.0, 0.56);
      final innerRect = RRect.fromRectAndRadius(rect.deflate(2.0), Radius.circular((radius - 1.5).clamp(0.0, radius)));
      final chromaPaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = premium ? 1.35 : 0.95
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            const Color(0xFF7DD3FC).withValues(alpha: chromaAlpha),
            Colors.transparent,
            const Color(0xFFC084FC).withValues(alpha: chromaAlpha * 0.9),
          ],
          stops: const [0.0, 0.5, 1.0],
        ).createShader(rect);
      canvas.drawRRect(innerRect, chromaPaint);
    }

    // 3. 顶部标志性镜面焦散光斑（紧贴卡片/胶囊上沿的锐利白光点 + 柔光扩散）
    final glintCx = (size.width * glintBias).clamp(radius + 16.0, math.max(radius + 16.0, size.width - radius - 16.0)).toDouble();
    final specWidth = (size.width * 0.52).clamp(28.0, 190.0).toDouble();
    final startX = (glintCx - specWidth / 2).clamp(radius * 0.5, size.width);
    final endX = (glintCx + specWidth / 2).clamp(0.0, size.width - radius * 0.5);

    if (endX > startX + 8) {
      // 柔和镜面光晕（向玻璃内部漫射 12px）
      final bloomRect = Rect.fromCenter(center: Offset(glintCx, 1.5), width: specWidth * 0.85, height: 22);
      final bloomPaint = Paint()
        ..shader = RadialGradient(
          center: Alignment.center,
          radius: 0.62,
          colors: [
            Colors.white.withValues(alpha: ((dark ? 0.42 : 0.72) + strength * 0.20).clamp(0.0, 0.92)),
            Colors.white.withValues(alpha: ((dark ? 0.12 : 0.24) + strength * 0.08).clamp(0.0, 0.40)),
            Colors.transparent,
          ],
          stops: const [0.0, 0.42, 1.0],
        ).createShader(bloomRect);
      canvas.save();
      canvas.clipRRect(RRect.fromRectAndRadius(rect, Radius.circular(radius)));
      canvas.drawOval(bloomRect, bloomPaint);
      canvas.restore();

      // 锐利顶沿高光弧线
      final specPaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.9 + strength * 0.75
        ..strokeCap = StrokeCap.round
        ..shader = LinearGradient(
          colors: [
            Colors.transparent,
            Colors.white.withValues(alpha: ((dark ? 0.78 : 0.96) + strength * 0.16).clamp(0.0, 1.0)),
            Colors.transparent,
          ],
        ).createShader(Rect.fromLTWH(startX, 0, endX - startX, 3));
      canvas.drawLine(Offset(startX, 1.0), Offset(endX, 1.0), specPaint);
    }

    // 4. 底部左下角微弱对称反光条（增强液态玻璃厚度立体感）
    final botWidth = (size.width * 0.34).clamp(20.0, 110.0);
    final botStart = (size.width * 0.18).clamp(radius * 0.6, size.width);
    final botEnd = (botStart + botWidth).clamp(0.0, size.width - radius * 0.6);
    if (botEnd > botStart + 8) {
      final botPaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.15
        ..strokeCap = StrokeCap.round
        ..shader = LinearGradient(
          colors: [
            Colors.transparent,
            Colors.white.withValues(alpha: ((dark ? 0.26 : 0.58) + strength * 0.14).clamp(0.0, 0.82)),
            Colors.transparent,
          ],
        ).createShader(Rect.fromLTWH(botStart, size.height - 2, botEnd - botStart, 2));
      canvas.drawLine(Offset(botStart, size.height - 1.1), Offset(botEnd, size.height - 1.1), botPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _LiquidRimPainter old) =>
      old.radius != radius ||
      old.dark != dark ||
      old.strength != strength ||
      old.premium != premium ||
      old.accent != accent ||
      old.glintBias != glintBias;
}

/// 窗口底色与 Apple 流体动态环境光场 / 自定义壁纸层。
/// - 开启「流体动态背景」时，以 26 秒无缝周期缓慢驱动多光晕流体极光网格，透过液态玻璃卡片实时折射流动；
/// - 测试模式（`!Glass.useShader`）或关闭流体背景时完全静止，零动画开销。
class GlassBackdrop extends StatefulWidget {
  final Widget child;
  const GlassBackdrop({super.key, required this.child});

  static Color? washFor(String preset) {
    const washes = {
      'sea': Color(0xFF2F6FDB),
      'dusk': Color(0xFF7B4EC9),
      'paper': Color(0xFFC8A064),
      'ink': Color(0xFF141820),
    };
    return washes[preset];
  }

  @override
  State<GlassBackdrop> createState() => _GlassBackdropState();
}

class _GlassBackdropState extends State<GlassBackdrop> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 26),
  );

  bool get _shouldAnimate =>
      Glass.useShader && Glass.enabled.value && Glass.fluidBg.value && !Glass.hasCustomBg;

  void _syncTicker() {
    if (_shouldAnimate) {
      if (!_ctrl.isAnimating) _ctrl.repeat();
    } else {
      if (_ctrl.isAnimating) _ctrl.stop();
    }
  }

  @override
  void initState() {
    super.initState();
    Glass.backdropListenable.addListener(_syncTicker);
    _syncTicker();
  }

  @override
  void dispose() {
    Glass.backdropListenable.removeListener(_syncTicker);
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Glass.backdropListenable,
      builder: (context, _) {
        final pal = AppColors.of(context);
        final base = pal.bg;
        final on = Glass.enabled.value;
        final imgPath = Glass.bgImage.value;
        final dim = Glass.bgDim.value;
        final hasImg = imgPath != null && imgPath.isNotEmpty && File(imgPath).existsSync();
        if (!on && !hasImg) {
          return ColoredBox(color: base, child: widget.child);
        }
        final dark = Theme.of(context).brightness == Brightness.dark;
        final wash = GlassBackdrop.washFor(Glass.preset.value);

        final fluidLayer = RepaintBoundary(
          child: AnimatedBuilder(
            animation: _ctrl,
            builder: (context, _) => CustomPaint(
              painter: _FluidMeshPainter(
                phase: _shouldAnimate ? _ctrl.value : 0.0,
                dark: dark,
                wash: wash,
              ),
              child: const SizedBox.expand(),
            ),
          ),
        );

        if (!hasImg) {
          return Stack(
            fit: StackFit.passthrough,
            children: [
              Positioned.fill(child: fluidLayer),
              widget.child,
            ],
          );
        }

        // 自定义背景图片：铺满裁切 + 可调柔和遮罩
        final scrimColor = dark ? Colors.black : Colors.white;
        return Stack(
          fit: StackFit.passthrough,
          children: [
            Positioned.fill(child: fluidLayer),
            Positioned.fill(
              child: Image.file(
                File(imgPath),
                fit: BoxFit.cover,
                filterQuality: FilterQuality.medium,
                errorBuilder: (_, _, _) => const SizedBox.shrink(),
              ),
            ),
            if (dim > 0.01)
              Positioned.fill(
                child: ColoredBox(
                  color: scrimColor.withValues(alpha: dim),
                ),
              ),
            widget.child,
          ],
        );
      },
    );
  }
}

/// Apple macOS Tahoe 流体动态光晕画笔：
/// 浅色模式为冰川蓝 + 薰衣草紫 + 暖杏桃珊瑚流动光团；
/// 深色模式为深钴蓝 + 皇家极光紫 + 幽蓝青流动光团，与概念图 95%+ 色域一致。
class _FluidMeshPainter extends CustomPainter {
  final double phase;
  final bool dark;
  final Color? wash;

  const _FluidMeshPainter({
    required this.phase,
    required this.dark,
    this.wash,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final rect = Offset.zero & size;
    final w = size.width;
    final h = size.height;
    final minDim = math.min(w, h);
    final maxDim = math.max(w, h);
    final t = phase * math.pi * 2.0;

    // 1. 基础底色
    canvas.drawRect(
      rect,
      Paint()..color = dark ? const Color(0xFF060A16) : const Color(0xFFEDF3FC),
    );

    // 2. 调色板（对齐概念图日/夜双色域，若用户选了背景预设则柔和融合）
    Color mix(Color target, double amount) => wash == null ? target : Color.lerp(target, wash!, amount)!;

    final orbs = dark
        ? <(Color, double, double, double, double, double, double)>[
            // (color, baseX, baseY, driftX, driftY, radiusFactor, alpha)
            (mix(const Color(0xFF6D28D9), 0.25), 0.44, 0.28, 0.10, 0.08, 0.62, 0.54),
            (mix(const Color(0xFF0D9488), 0.22), 0.84, 0.34, -0.09, 0.10, 0.56, 0.48),
            (mix(const Color(0xFF2563EB), 0.25), 0.26, 0.78, 0.11, -0.09, 0.60, 0.52),
            (mix(const Color(0xFF7C3AED), 0.20), 0.72, 0.76, -0.08, -0.08, 0.50, 0.36),
            (mix(const Color(0xFF0284C7), 0.20), 0.18, 0.18, 0.07, 0.09, 0.48, 0.34),
          ]
        : <(Color, double, double, double, double, double, double)>[
            (mix(const Color(0xFF7DD3FC), 0.22), 0.20, 0.16, 0.10, 0.08, 0.64, 0.72),
            (mix(const Color(0xFFC4B5FD), 0.24), 0.52, 0.26, -0.10, 0.09, 0.56, 0.68),
            (mix(const Color(0xFFFDBA74), 0.20), 0.80, 0.40, -0.08, -0.09, 0.54, 0.66),
            (mix(const Color(0xFFFCA5A5), 0.18), 0.32, 0.78, 0.11, -0.08, 0.56, 0.62),
            (mix(const Color(0xFF93C5FD), 0.22), 0.76, 0.84, -0.09, 0.07, 0.52, 0.54),
          ];

    // 3. 逐层绘制平滑 Lissajous 流体光团
    for (var i = 0; i < orbs.length; i++) {
      final (color, bx, by, dx, dy, rf, alpha) = orbs[i];
      final angle1 = t + i * 1.25;
      final angle2 = t * (i.isEven ? 1.0 : -1.0) + i * 0.85;
      final cx = w * (bx + dx * math.sin(angle1));
      final cy = h * (by + dy * math.cos(angle2));
      final breath = 1.0 + 0.07 * math.sin(t + i * 1.7);
      final radius = (maxDim * rf * 0.72 + minDim * 0.18) * breath;

      final orbRect = Rect.fromCircle(center: Offset(cx, cy), radius: radius);
      final paint = Paint()
        ..shader = RadialGradient(
          colors: [
            color.withValues(alpha: alpha),
            color.withValues(alpha: alpha * 0.45),
            color.withValues(alpha: 0.0),
          ],
          stops: const [0.0, 0.52, 1.0],
        ).createShader(orbRect);
      canvas.drawCircle(Offset(cx, cy), radius, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _FluidMeshPainter old) =>
      old.phase != phase || old.dark != dark || old.wash != wash;
}

/// 液态玻璃便利贴/内容卡片表面：
/// 实时监听 `Glass.opacity` / `Glass.refraction` / `Glass.quality`，具备高通透毛玻璃折射、
/// Fresnel 液态双层镜面边缘、顶部聚焦高光光斑、可选重要级别微染色与拖拽/悬停立体阴影。
class SpecularGlassCard extends StatelessWidget {
  final Widget child;
  final double radius;
  final bool hover;
  final bool elevated;
  final Color? tintAccent;

  const SpecularGlassCard({
    super.key,
    required this.child,
    this.radius = 20,
    this.hover = false,
    this.elevated = false,
    this.tintAccent,
  });

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Glass.backdropListenable,
      builder: (context, _) {
        final c = AppColors.of(context);
        final dark = Theme.of(context).brightness == Brightness.dark;
        final alpha = Glass.opacity.value;
        final ior = Glass.refraction.value;
        final qName = Glass.quality.value;
        final translucent = Glass.surfaceTranslucent;

        if (!translucent) {
          final solid = tintAccent != null
              ? Color.lerp(hover ? c.hover : c.elevated, tintAccent, dark ? 0.22 : 0.14)!
              : (hover ? c.hover : c.elevated);
          return DecoratedBox(
            decoration: BoxDecoration(
              color: solid,
              borderRadius: BorderRadius.circular(radius),
              border: Border.all(color: tintAccent?.withValues(alpha: 0.45) ?? c.separator),
            ),
            child: child,
          );
        }

        final rStr = Glass.refractionStrength(ior, qName);
        final blur = Glass.blurSigmaFor(alpha, qName);
        final active = hover || elevated;
        // 保持高通透度，让底层流体极光清晰折射穿透玻璃卡片
        final baseAlpha = dark
            ? (active ? (alpha * 0.58).clamp(0.18, 0.56) : (alpha * 0.38).clamp(0.12, 0.44))
            : (active ? (alpha * 0.84).clamp(0.26, 0.68) : (alpha * 0.62).clamp(0.20, 0.56));
        final baseColor = tintAccent != null
            ? Color.lerp(c.elevated, tintAccent, dark ? 0.30 : 0.20)!.withValues(alpha: baseAlpha)
            : c.elevated.withValues(alpha: baseAlpha);

        return AnimatedContainer(
          duration: Motion.short3,
          curve: Curves.easeOutCubic,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(radius),
            boxShadow: [
              BoxShadow(
                color: (tintAccent != null && active ? tintAccent! : Colors.black).withValues(
                  alpha: dark ? (elevated ? 0.58 : hover ? 0.46 : 0.34) : (elevated ? 0.18 : hover ? 0.12 : 0.07),
                ),
                blurRadius: elevated ? 34 : (hover ? 26 : 18),
                spreadRadius: elevated ? 2 : 0,
                offset: Offset(0, elevated ? 16 : (hover ? 10 : 6)),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(radius),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
              child: CustomPaint(
                foregroundPainter: _LiquidRimPainter(
                  radius: radius,
                  dark: dark,
                  strength: active ? (rStr + 0.24).clamp(0.0, 1.0) : rStr,
                  premium: qName == 'premium',
                  accent: tintAccent,
                  glintBias: 0.68,
                ),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(radius),
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        Color.alphaBlend(
                          Colors.white.withValues(alpha: (dark ? 0.12 : 0.52) + rStr * (dark ? 0.08 : 0.14)),
                          baseColor,
                        ),
                        baseColor,
                        Color.alphaBlend(
                          (tintAccent ?? Colors.black).withValues(alpha: dark ? 0.18 : 0.04),
                          baseColor,
                        ),
                      ],
                      stops: const [0.0, 0.48, 1.0],
                    ),
                  ),
                  child: Stack(
                    fit: StackFit.passthrough,
                    children: [
                      // 顶部液态焦散漫反射光晕
                      Positioned(
                        top: -20,
                        left: -8,
                        right: -8,
                        height: 52,
                        child: IgnorePointer(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: RadialGradient(
                                center: const Alignment(0.32, -0.45),
                                radius: 0.72,
                                colors: [
                                  Colors.white.withValues(
                                    alpha: ((dark ? 0.16 : 0.38) + rStr * (dark ? 0.12 : 0.20) + (active ? 0.08 : 0.0))
                                        .clamp(0.0, 0.78),
                                  ),
                                  Colors.transparent,
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                      child,
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 侧边栏 / 抽屉 / 顶栏 / 底栏液态玻璃容器。
class Frosted extends StatelessWidget {
  final Widget child;
  final Color color;
  final BoxBorder? border;
  final double radius;
  const Frosted({
    super.key,
    required this.child,
    required this.color,
    this.border,
    this.radius = 0,
  });

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Glass.backdropListenable,
      builder: (context, _) {
        final on = Glass.enabled.value;
        if (!on && !Glass.hasCustomBg) {
          return DecoratedBox(
            decoration: BoxDecoration(
              color: color,
              border: border,
              borderRadius: radius > 0 ? BorderRadius.circular(radius) : null,
            ),
            child: child,
          );
        }
        final alpha = Glass.opacity.value;
        final ior = Glass.refraction.value;
        final qName = Glass.quality.value;
        final dark = Theme.of(context).brightness == Brightness.dark;
        final dpr = MediaQuery.devicePixelRatioOf(context);
        final bend = Glass.refractsAt(dpr);
        final rStr = Glass.refractionStrength(ior, qName);
        final blur = Glass.blurSigmaFor(alpha, qName);

        if (radius > 0 && Glass.useShader && on && qName != 'minimal') {
          return GlassContainer(
            useOwnLayer: true,
            quality: Glass.resolveQuality(qName),
            clipBehavior: Clip.antiAlias,
            shape: LiquidRoundedSuperellipse(borderRadius: radius),
            settings: LiquidGlassSettings(
              glassColor: color.withValues(alpha: (alpha * 0.76).clamp(0.16, 0.76)),
              blur: blur,
              thickness: bend ? (10.0 + rStr * 16.0) : 0,
              refractiveIndex: bend ? ior : 1.0,
              saturation: (dark ? 1.28 : 1.20) + rStr * 0.25,
              lightIntensity: (dark ? 0.44 : 0.58) + rStr * 0.28,
              glowIntensity: (dark ? 0.22 : 0.20) + rStr * 0.25,
              chromaticAberration: bend ? (0.015 + rStr * 0.06) : 0,
              bodyMode: GlassBodyMode.clear,
            ),
            child: CustomPaint(
              foregroundPainter: _LiquidRimPainter(
                radius: radius,
                dark: dark,
                strength: rStr,
                premium: qName == 'premium',
              ),
              child: child,
            ),
          );
        }

        final topSheen = dark
            ? Colors.white.withValues(alpha: 0.07 + rStr * 0.05)
            : Colors.white.withValues(alpha: 0.52 + rStr * 0.14);
        final effAlpha = (alpha * (dark ? 0.86 : 0.88)).clamp(0.24, 0.86);
        final innerBox = DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Color.alphaBlend(topSheen, color.withValues(alpha: effAlpha)),
                color.withValues(alpha: (effAlpha + 0.06).clamp(0.28, 0.90)),
              ],
            ),
            border: border,
            borderRadius: radius > 0 ? BorderRadius.circular(radius) : null,
          ),
          child: child,
        );
        if (radius > 0) {
          return ClipRRect(
            borderRadius: BorderRadius.circular(radius),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
              child: innerBox,
            ),
          );
        }
        return ClipRect(
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
            child: innerBox,
          ),
        );
      },
    );
  }
}

/// Spotlight 全屏检视浮窗（96.4vw × 95.6vh 液态玻璃浮层，四周保留极窄呼吸留白）。
Future<void> showSpotlightModal(BuildContext context, {required String title, required Widget child}) {
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: '关闭全屏视图',
    barrierColor: Colors.black54,
    transitionDuration: Motion.medium1,
    pageBuilder: (ctx, a1, a2) {
      final size = MediaQuery.sizeOf(ctx);
      final c = AppColors.of(ctx);
      final tt = Theme.of(ctx).textTheme;
      return Center(
        child: SizedBox(
          key: const Key('spotlightModal'),
          width: (size.width * 0.964).clamp(300.0, 2400.0),
          height: (size.height * 0.956).clamp(240.0, 1600.0),
          child: Glass(
            radius: AppRadius.xl,
            child: Material(
              type: MaterialType.transparency,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(AppRadius.xl),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Container(
                      height: Sizes.bar,
                      padding: const EdgeInsets.symmetric(horizontal: Gap.l),
                      decoration: BoxDecoration(
                        color: c.sidebar.withValues(alpha: 0.60),
                        border: Border(bottom: BorderSide(color: c.separator)),
                      ),
                      child: Row(
                        children: [
                          Icon(CupertinoIcons.sparkles, size: Sizes.iconSm, color: c.accent),
                          const SizedBox(width: Gap.m),
                          Expanded(
                            child: Text(
                              title.isEmpty ? '无标题' : title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: tt.titleMedium,
                            ),
                          ),
                          IconButton(
                            key: const Key('closeSpotlight'),
                            tooltip: '退出全屏 (Esc)',
                            icon: const Icon(CupertinoIcons.fullscreen_exit, size: Sizes.iconSm + 2),
                            onPressed: () => Navigator.of(ctx).pop(),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: ColoredBox(
                        color: c.bg.withValues(alpha: Glass.surfaceTranslucent ? 0.86 : 1.0),
                        child: child,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    },
    transitionBuilder: (ctx, animation, secondaryAnimation, dialogChild) =>
        MotionFade(animation: animation, child: dialogChild),
  );
}

/// 页面底色同步主题。
ThemeData glassTheme(ThemeData base, bool on) {
  if (!on) return base;
  final bg = base.scaffoldBackgroundColor;
  return base.copyWith(
    scaffoldBackgroundColor: bg,
    appBarTheme: base.appBarTheme.copyWith(backgroundColor: bg, surfaceTintColor: Colors.transparent),
  );
}

/// [HIG] 弹簧，用于菜单 / 快速切换器出现。
final springCurve = SpringCurve(Springs.smooth);
