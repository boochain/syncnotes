import 'dart:io';
import 'dart:ui';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import 'ds.dart';
import 'motion.dart';
import 'theme.dart';
import 'tokens.dart';

/// 浮层与导航栏材质（基于开源 `liquid_glass_widgets` 实现 Apple HIG 液态玻璃效果）。
///
/// 配备实时折射、高饱和度透光、顶部镜面高光光晕与分层阴影；
/// 2.5x 及以上高分屏关闭重折射（避免同一页被采样出双影），仍保留强模糊与高光质感。
class Glass extends StatelessWidget {
  static bool useShader = true;

  /// 液态玻璃总开关。测试里默认关闭，避免着色器动画阻塞 pumpAndSettle。
  static final enabled = ValueNotifier<bool>(true);

  /// 浮层不透明度（0.22 – 0.88，默认 0.42 让折射与背景层次清晰可见）。
  static final opacity = ValueNotifier<double>(0.42);

  /// 折射率（1.00 – 1.12，默认 1.06）。
  static final refraction = ValueNotifier<double>(1.06);

  /// 着色器质量档位：standard（全平台轻量 2D 着色器）/ premium（高阶折射高光）/ minimal（纯 BackdropFilter）
  static final quality = ValueNotifier<String>('standard');

  /// 背景色调预设：default / sea / dusk / paper / ink
  static final preset = ValueNotifier<String>('default');

  /// 自定义背景图片路径（支持本地 PNG / JPG / WebP 壁纸）。
  static final bgImage = ValueNotifier<String?>(null);

  /// 自定义背景图片之上的可读性遮罩浓度（0.00 – 0.88，默认 0.35）。
  static final bgDim = ValueNotifier<double>(0.35);

  /// 合并监听液态玻璃与背景图片变化。
  static Listenable get backdropListenable => Listenable.merge([enabled, preset, bgImage, bgDim, opacity]);

  /// 是否设置了有效的自定义背景图片。
  static bool get hasCustomBg {
    final p = bgImage.value;
    return p != null && p.isNotEmpty;
  }

  /// 真实运行时且开启液态玻璃或自定义背景图时，允许内层 Scaffold 透出底层 GlassBackdrop 壁纸。
  static bool get surfaceTranslucent => useShader && (enabled.value || hasCustomBg);

  /// 内层页面 Scaffold 背景色：开启液态玻璃或壁纸时透明（由 GlassBackdrop 统一绘制壁纸与光晕），测试或关闭时保持主题底色。
  static Color? scaffoldBg(BuildContext context) => surfaceTranslucent ? Colors.transparent : null;

  /// 折射只在较低缩放比上打开。3.5x 上折射会复制出第二层画面。
  static bool refractsAt(double dpr) => dpr > 0 && dpr < 2.5;

  static GlassQuality resolveQuality(String q) => switch (q) {
        'premium' => GlassQuality.premium,
        _ => GlassQuality.standard,
      };

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
    return ValueListenableBuilder<bool>(
      valueListenable: enabled,
      builder: (context, on, _) => ValueListenableBuilder<double>(
        valueListenable: opacity,
        builder: (context, alpha, _) => ValueListenableBuilder<double>(
          valueListenable: refraction,
          builder: (context, ior, _) => ValueListenableBuilder<String>(
            valueListenable: quality,
            builder: (context, qName, _) {
              final inner = padding == null ? child : Padding(padding: padding!, child: child);
              final deco = floatingDecoration(context, radius: radius);
              final c = AppColors.of(context);
              final dpr = MediaQuery.devicePixelRatioOf(context);
              final bend = refractsAt(dpr);
              final dark = Theme.of(context).brightness == Brightness.dark;
              final q = resolveQuality(qName);
              final shaderActive = useShader && on && qName != 'minimal' && radius > 0;
              final rimColor = dark
                  ? Colors.white.withValues(alpha: 0.24)
                  : Colors.white.withValues(alpha: 0.82);
              final Widget body;
              if (shaderActive) {
                body = GlassContainer(
                  useOwnLayer: true,
                  quality: q,
                  clipBehavior: Clip.antiAlias,
                  shape: LiquidRoundedSuperellipse(borderRadius: radius),
                  settings: LiquidGlassSettings(
                    glassColor: tint(context, frosted: true, alpha: alpha),
                    blur: bend ? 22 : 28,
                    thickness: bend ? 10 : 0,
                    refractiveIndex: bend ? ior : 1.0,
                    saturation: dark ? 1.32 : 1.24,
                    lightIntensity: dark ? 0.40 : 0.54,
                    glowIntensity: dark ? 0.26 : 0.22,
                    chromaticAberration: bend ? 0.016 : 0,
                    bodyMode: GlassBodyMode.clear,
                  ),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.white.withValues(alpha: dark ? 0.12 : 0.42),
                          Colors.transparent,
                          Colors.black.withValues(alpha: dark ? 0.08 : 0.02),
                        ],
                        stops: const [0.0, 0.38, 1.0],
                      ),
                    ),
                    child: inner,
                  ),
                );
              } else if (on) {
                body = ClipRRect(
                  borderRadius: BorderRadius.circular(radius),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 28, sigmaY: 28),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Color.alphaBlend(
                              Colors.white.withValues(alpha: dark ? 0.10 : 0.46),
                              tint(context, frosted: true, alpha: alpha),
                            ),
                            tint(context, frosted: true, alpha: (alpha + 0.08).clamp(0.22, 0.90)),
                          ],
                        ),
                      ),
                      child: inner,
                    ),
                  ),
                );
              } else {
                body = DecoratedBox(
                  decoration: BoxDecoration(color: tint(context, frosted: false), borderRadius: BorderRadius.circular(radius)),
                  child: inner,
                );
              }
              if (shaderActive) {
                final seShape = ContinuousRectangleBorder(
                  borderRadius: BorderRadius.circular(radius),
                  side: BorderSide(color: Color.lerp(c.separator, rimColor, 0.68)!, width: 1),
                );
                return Padding(
                  padding: margin ?? EdgeInsets.zero,
                  child: DecoratedBox(
                    position: DecorationPosition.foreground,
                    decoration: ShapeDecoration(shape: seShape),
                    child: DecoratedBox(
                      decoration: ShapeDecoration(
                        shape: ContinuousRectangleBorder(borderRadius: BorderRadius.circular(radius)),
                        shadows: deco.boxShadow,
                      ),
                      child: body,
                    ),
                  ),
                );
              }
              return Padding(
                padding: margin ?? EdgeInsets.zero,
                child: DecoratedBox(
                  position: DecorationPosition.foreground,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(radius),
                    border: on ? Border.all(color: Color.lerp(c.separator, rimColor, 0.58)!) : null,
                  ),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(radius),
                      boxShadow: on ? deco.boxShadow : const [],
                    ),
                    child: body,
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

/// 窗口底色与 Apple 环境光场 / 自定义壁纸层。
/// 浅色模式为柔和天蓝 + 薰衣草紫 + 暖杏桃三光晕；深色模式为深钴蓝 + 皇家紫 + 幽蓝青三光晕，
/// 衬托液态玻璃卡片与浮岛的镜面高光与折射层次。
class GlassBackdrop extends StatelessWidget {
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
          return ColoredBox(color: base, child: child);
        }
        final dark = Theme.of(context).brightness == Brightness.dark;
        final name = Glass.preset.value;
        final wash = washFor(name);

        // 严格对齐展示图日夜双模式的三光晕 Apple Tahoe / iOS 26 光场
        final orb1 = wash != null
            ? Color.lerp(wash, dark ? const Color(0xFF2563EB) : const Color(0xFF7DD3FC), 0.35)!
            : (dark ? const Color(0xFF2563EB) : const Color(0xFF8CCBFF));
        final orb2 = wash != null
            ? Color.lerp(wash, dark ? const Color(0xFF7C3AED) : const Color(0xFFD8B4FE), 0.45)!
            : (dark ? const Color(0xFF7C3AED) : const Color(0xFFD5B6FF));
        final orb3 = wash != null
            ? Color.lerp(wash, dark ? const Color(0xFF0D9488) : const Color(0xFFFDBA74), 0.40)!
            : (dark ? const Color(0xFF0D9488) : const Color(0xFFFDC89E));

        final ambientMesh = Stack(
          fit: StackFit.passthrough,
          children: [
            Positioned.fill(
              child: ColoredBox(
                color: dark ? const Color(0xFF0C0F1A) : const Color(0xFFF2F5FB),
              ),
            ),
            // 左上主光晕（浅色天蓝 / 深色钴蓝）
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: const Alignment(-0.78, -0.72),
                    radius: 1.05,
                    colors: [
                      orb1.withValues(alpha: dark ? 0.42 : 0.48),
                      orb1.withValues(alpha: 0.0),
                    ],
                  ),
                ),
              ),
            ),
            // 中右柔和光晕（浅色薰衣草紫 / 深色皇家紫）
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: const Alignment(0.32, -0.18),
                    radius: 0.92,
                    colors: [
                      orb2.withValues(alpha: dark ? 0.38 : 0.40),
                      orb2.withValues(alpha: 0.0),
                    ],
                  ),
                ),
              ),
            ),
            // 右下与左下暖/青平衡光晕（浅色暖杏桃 / 深色幽蓝青）
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: const Alignment(0.78, 0.55),
                    radius: 0.98,
                    colors: [
                      orb3.withValues(alpha: dark ? 0.34 : 0.42),
                      orb3.withValues(alpha: 0.0),
                    ],
                  ),
                ),
              ),
            ),
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: const Alignment(-0.42, 0.88),
                    radius: 0.85,
                    colors: [
                      orb3.withValues(alpha: dark ? 0.18 : 0.32),
                      orb3.withValues(alpha: 0.0),
                    ],
                  ),
                ),
              ),
            ),
          ],
        );

        if (!hasImg) {
          return Stack(
            fit: StackFit.passthrough,
            children: [
              Positioned.fill(child: RepaintBoundary(child: ambientMesh)),
              child,
            ],
          );
        }
        return Stack(
          fit: StackFit.passthrough,
          children: [
            Positioned.fill(
              child: Image.file(
                File(imgPath),
                key: ValueKey('bgImg:$imgPath'),
                fit: BoxFit.cover,
                alignment: Alignment.center,
                filterQuality: FilterQuality.medium,
                errorBuilder: (ctx, err, stack) => ambientMesh,
              ),
            ),
            if (dim > 0)
              Positioned.fill(
                child: ColoredBox(
                  color: base.withValues(alpha: dim.clamp(0.0, 0.88)),
                ),
              ),
            child,
          ],
        );
      },
    );
  }
}

/// 液态玻璃便利贴卡片表面：高斯毛玻璃 + 顶部居中镜面星芒高光 + 通透描边 + 悬停微抬升阴影。
class SpecularGlassCard extends StatelessWidget {
  final Widget child;
  final double radius;
  final bool hover;
  final Color? tintAccent;

  const SpecularGlassCard({
    super.key,
    required this.child,
    this.radius = 18,
    this.hover = false,
    this.tintAccent,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final alpha = Glass.opacity.value;
    final translucent = Glass.surfaceTranslucent;

    if (!translucent) {
      return DecoratedBox(
        decoration: BoxDecoration(
          color: hover ? c.hover : c.elevated,
          borderRadius: BorderRadius.circular(radius),
          border: Border.all(color: c.separator),
        ),
        child: child,
      );
    }

    final baseAlpha = dark
        ? (hover ? (alpha * 0.78).clamp(0.28, 0.72) : (alpha * 0.56).clamp(0.20, 0.58))
        : (hover ? (alpha * 1.15).clamp(0.42, 0.82) : (alpha * 0.92).clamp(0.32, 0.72));
    final baseColor = tintAccent != null
        ? Color.lerp(c.elevated, tintAccent, dark ? 0.14 : 0.08)!.withValues(alpha: baseAlpha)
        : c.elevated.withValues(alpha: baseAlpha);

    final rimColor = dark
        ? Colors.white.withValues(alpha: hover ? 0.34 : 0.18)
        : Colors.white.withValues(alpha: hover ? 0.92 : 0.72);

    return AnimatedContainer(
      duration: Motion.short3,
      curve: Curves.easeOutCubic,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: dark ? (hover ? 0.44 : 0.30) : (hover ? 0.12 : 0.07)),
            blurRadius: hover ? 26 : 18,
            offset: Offset(0, hover ? 10 : 6),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(radius),
              border: Border.all(color: rimColor, width: 1),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Color.alphaBlend(
                    Colors.white.withValues(alpha: dark ? 0.12 : 0.48),
                    baseColor,
                  ),
                  baseColor,
                  Color.alphaBlend(
                    Colors.black.withValues(alpha: dark ? 0.14 : 0.03),
                    baseColor,
                  ),
                ],
                stops: const [0.0, 0.46, 1.0],
              ),
            ),
            child: Stack(
              fit: StackFit.passthrough,
              children: [
                // 顶部边缘镜面高光带（Apple Liquid Glass 标志性顶部折射光晕）
                Positioned(
                  top: 0,
                  left: 16,
                  right: 16,
                  height: 2,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          Colors.transparent,
                          Colors.white.withValues(alpha: dark ? (hover ? 0.72 : 0.48) : (hover ? 1.0 : 0.88)),
                          Colors.transparent,
                        ],
                      ),
                    ),
                  ),
                ),
                Positioned(
                  top: -18,
                  left: 0,
                  right: 0,
                  height: 44,
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: RadialGradient(
                          center: const Alignment(0, -0.4),
                          radius: 0.72,
                          colors: [
                            Colors.white.withValues(alpha: dark ? (hover ? 0.16 : 0.10) : (hover ? 0.42 : 0.28)),
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
    );
  }
}

/// 侧边栏 / 抽屉 / 顶栏 / 底栏液态玻璃容器。
///
/// 针对平直通栏（`radius <= 0`）：使用 `ClipRect` + 强高斯毛玻璃（sigma 30）+ 顶部镜面高光渐变；
/// 针对圆角浮岛（`radius > 0`）：使用 `liquid_glass_widgets` 的 `GlassContainer` 与真实折射高光。
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
      listenable: Listenable.merge([Glass.enabled, Glass.opacity, Glass.refraction, Glass.quality, Glass.bgImage]),
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
        final rimColor = dark
            ? Colors.white.withValues(alpha: 0.20)
            : Colors.white.withValues(alpha: 0.72);

        if (radius > 0 && Glass.useShader && on && qName != 'minimal') {
          return DecoratedBox(
            position: DecorationPosition.foreground,
            decoration: BoxDecoration(
              border: border ?? Border.all(color: rimColor),
              borderRadius: BorderRadius.circular(radius),
            ),
            child: GlassContainer(
              useOwnLayer: true,
              quality: Glass.resolveQuality(qName),
              clipBehavior: Clip.antiAlias,
              shape: LiquidRoundedSuperellipse(borderRadius: radius),
              settings: LiquidGlassSettings(
                glassColor: color.withValues(alpha: alpha),
                blur: 26,
                thickness: bend ? 8 : 0,
                refractiveIndex: bend ? ior : 1.0,
                saturation: dark ? 1.28 : 1.20,
                lightIntensity: dark ? 0.34 : 0.46,
                glowIntensity: dark ? 0.20 : 0.18,
                chromaticAberration: bend ? 0.012 : 0,
                bodyMode: GlassBodyMode.clear,
              ),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.white.withValues(alpha: dark ? 0.08 : 0.30),
                      Colors.transparent,
                    ],
                  ),
                ),
                child: child,
              ),
            ),
          );
        }

        final topSheen = dark
            ? Colors.white.withValues(alpha: 0.09)
            : Colors.white.withValues(alpha: 0.52);
        final effAlpha = (alpha * 0.92).clamp(0.22, 0.86);
        final innerBox = DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Color.alphaBlend(topSheen, color.withValues(alpha: effAlpha)),
                color.withValues(alpha: (effAlpha + 0.06).clamp(0.26, 0.90)),
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
              filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
              child: innerBox,
            ),
          );
        }
        return ClipRect(
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
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
    transitionDuration: Motion.short4,
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
