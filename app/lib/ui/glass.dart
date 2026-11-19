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
/// 页面内容保持高可读性对比度，切换时不会叠出上一页。
/// 2.5x 及以上高分屏关闭重折射（避免同一页被采样出双影），但仍走液态玻璃着色器的模糊与高光。
class Glass extends StatelessWidget {
  static bool useShader = true;

  /// 液态玻璃总开关。测试里默认关闭，避免着色器动画阻塞 pumpAndSettle。
  static final enabled = ValueNotifier<bool>(true);

  /// 浮层不透明度（0.35 – 0.92）。
  static final opacity = ValueNotifier<double>(0.55);

  /// 折射率（1.00 – 1.12）。
  static final refraction = ValueNotifier<double>(1.04);

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

  /// 内层页面 Scaffold 背景色：开启液态玻璃或壁纸时透明（由 GlassBackdrop 统一绘制壁纸与可读性遮罩），测试或关闭时保持主题底色。
  static Color? scaffoldBg(BuildContext context) => surfaceTranslucent ? Colors.transparent : null;

  /// 折射只在较低缩放比上打开。3.5x 上折射会复制出第二层画面。
  static bool refractsAt(double dpr) => dpr > 0 && dpr < 2.5;

  static GlassQuality resolveQuality(String q) => switch (q) {
        'premium' => GlassQuality.premium,
        'minimal' => GlassQuality.minimal,
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

  static Color tint(BuildContext context, {required bool frosted, double alpha = 0.55}) {
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
              final shaderActive = useShader && on && q != GlassQuality.minimal && radius > 0;
              final Widget body;
              if (shaderActive) {
                body = GlassContainer(
                  useOwnLayer: true,
                  quality: q,
                  clipBehavior: Clip.antiAlias,
                  shape: LiquidRoundedSuperellipse(borderRadius: radius),
                  settings: LiquidGlassSettings(
                    glassColor: tint(context, frosted: true, alpha: alpha),
                    blur: bend ? 14 : 20,
                    thickness: bend ? 6 : 0,
                    refractiveIndex: bend ? ior : 1.0,
                    saturation: dark ? 1.14 : 1.08,
                    lightIntensity: dark ? 0.28 : 0.38,
                    glowIntensity: dark ? 0.16 : 0.14,
                    chromaticAberration: 0,
                    bodyMode: GlassBodyMode.clear,
                  ),
                  child: inner,
                );
              } else if (on) {
                body = ClipRRect(
                  borderRadius: BorderRadius.circular(radius),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                    child: ColoredBox(color: tint(context, frosted: true, alpha: alpha), child: inner),
                  ),
                );
              } else {
                body = DecoratedBox(
                  decoration: BoxDecoration(color: tint(context, frosted: false), borderRadius: BorderRadius.circular(radius)),
                  child: inner,
                );
              }
              if (shaderActive) {
                // 使用与 LiquidRoundedSuperellipse 完全一致的超椭圆曲线绘制边框与阴影，消除四角双线错位
                final seShape = RoundedSuperellipseBorder(
                  borderRadius: BorderRadius.circular(radius),
                  side: BorderSide(color: c.border),
                );
                return Padding(
                  padding: margin ?? EdgeInsets.zero,
                  child: DecoratedBox(
                    position: DecorationPosition.foreground,
                    decoration: ShapeDecoration(shape: seShape),
                    child: DecoratedBox(
                      decoration: ShapeDecoration(
                        shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(radius)),
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
                    border: on ? deco.border : null,
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

/// 窗口底色与自定义壁纸层。
/// 支持用户自定义背景图片（带可调可读性遮罩）或 Apple 风格环境色晕渐变（白天清透银白、黑夜深邃曜石黑）。
class GlassBackdrop extends StatelessWidget {
  final Widget child;
  const GlassBackdrop({super.key, required this.child});

  static Color? washFor(String preset) {
    const washes = {
      'sea': Color(0xFF2F6FDB),
      'dusk': Color(0xFF6B4C9A),
      'paper': Color(0xFFC4A574),
      'ink': Color(0xFF111111),
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
        final topTint = wash != null
            ? Color.lerp(base, wash, dark ? 0.38 : 0.45)!
            : (dark ? const Color(0xFF121824) : const Color(0xFFEEF2F8));
        final midTint = wash != null
            ? Color.lerp(base, wash, dark ? 0.16 : 0.18)!
            : (dark ? const Color(0xFF17171A) : const Color(0xFFF5F5F7));
        if (!hasImg) {
          return DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [topTint, midTint, base],
                stops: const [0.0, 0.52, 1.0],
              ),
            ),
            child: child,
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
                errorBuilder: (_, _, _) => DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [topTint, midTint, base],
                    ),
                  ),
                ),
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

/// 侧边栏 / 抽屉 / 顶栏 / 底栏液态玻璃容器。
///
/// 针对平直通栏（`radius <= 0`）：使用无圆角 `ClipRect` + 高斯毛玻璃 + Apple HIG 高光细线，
/// 彻底避免 `LiquidRoundedSuperellipse(borderRadius: 0)` 在直角边缘产生法线除零或裁切闪烁问题；
/// 针对圆角卡片（`radius > 0`）：使用 `liquid_glass_widgets` 的 `GlassContainer` 与超椭圆边框。
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
      listenable: Listenable.merge([Glass.enabled, Glass.opacity, Glass.quality, Glass.bgImage]),
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
        final qName = Glass.quality.value;
        final dark = Theme.of(context).brightness == Brightness.dark;
        final q = Glass.resolveQuality(qName);
        final dpr = MediaQuery.devicePixelRatioOf(context);
        final bend = Glass.refractsAt(dpr);
        // 仅当 radius > 0 时启用超椭圆着色器；radius == 0 的通栏（顶栏、侧边栏、底栏）使用稳健的 ClipRect + BackdropFilter
        if (radius > 0 && Glass.useShader && on && q != GlassQuality.minimal) {
          return DecoratedBox(
            position: DecorationPosition.foreground,
            decoration: BoxDecoration(
              border: border,
              borderRadius: BorderRadius.circular(radius),
            ),
            child: GlassContainer(
              useOwnLayer: true,
              quality: GlassQuality.standard,
              clipBehavior: Clip.antiAlias,
              shape: LiquidRoundedSuperellipse(borderRadius: radius),
              settings: LiquidGlassSettings(
                glassColor: color.withValues(alpha: alpha),
                blur: 20,
                thickness: bend ? 4 : 0,
                refractiveIndex: bend ? 1.02 : 1.0,
                saturation: dark ? 1.10 : 1.05,
                lightIntensity: dark ? 0.20 : 0.28,
                glowIntensity: 0.12,
                chromaticAberration: 0,
                bodyMode: GlassBodyMode.clear,
              ),
              child: child,
            ),
          );
        }
        final highlight = dark
            ? Colors.white.withValues(alpha: 0.06)
            : Colors.white.withValues(alpha: 0.42);
        final innerBox = DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Color.alphaBlend(highlight, color.withValues(alpha: alpha)),
                color.withValues(alpha: (alpha + 0.06).clamp(0.35, 0.94)),
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
              filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
              child: innerBox,
            ),
          );
        }
        return ClipRect(
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
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
    pageBuilder: (ctx, _, _) {
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
                        color: c.sidebar.withValues(alpha: 0.72),
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
                        color: c.bg.withValues(alpha: Glass.surfaceTranslucent ? 0.88 : 1.0),
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
    transitionBuilder: (_, animation, _, dialogChild) => MotionFade(animation: animation, child: dialogChild),
  );
}

/// 页面保持不透明。透明 Scaffold 会让渐变和上一页透出来，玻璃再采样一次就叠成两层。
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
