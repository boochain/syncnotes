// SyncNotes 设计令牌（Design Tokens）
//
// 所有数值均取自主流设计规范，而非自创。来源缩写：
//   [HIG]    Apple Human Interface Guidelines（Color / Typography / Materials / Motion，iOS 26 Liquid Glass）
//   [M3]     Google Material Design 3（m3.material.io：color roles, type scale, shape, elevation, motion）
//   [Fluent] Microsoft Fluent 2（fluent2.microsoft.design：color tokens, type ramp, spacing, corner radius, shadow, motion）
// 完整说明见 docs/design-system.md。
import 'dart:io' show Platform;

import 'package:flutter/animation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/physics.dart';

/// 平台设计语言：Windows → Fluent，Android/Linux → Material 3；Liquid Glass 材质在所有平台保持一致。
enum DesignLanguage { fluent, material }

DesignLanguage get currentLanguage {
  try {
    if (Platform.isWindows) return DesignLanguage.fluent;
  } catch (_) {}
  return DesignLanguage.material;
}

// ---------------------------------------------------------------- color

/// [HIG] System colors（iOS，浅色 / 深色）。
abstract final class HigColors {
  static const blue = (Color(0xFF007AFF), Color(0xFF0A84FF));
  static const green = (Color(0xFF34C759), Color(0xFF30D158));
  static const orange = (Color(0xFFFF9500), Color(0xFFFF9F0A));
  static const red = (Color(0xFFFF3B30), Color(0xFFFF453A));
  static const pink = (Color(0xFFFF2D55), Color(0xFFFF375F));
  static const purple = (Color(0xFFAF52DE), Color(0xFFBF5AF2));
  static const indigo = (Color(0xFF5856D6), Color(0xFF5E5CE6));
  static const teal = (Color(0xFF30B0C7), Color(0xFF40C8E0));
  static const yellow = (Color(0xFFFFCC00), Color(0xFFFFD60A));
  static const gray = (Color(0xFF8E8E93), Color(0xFF8E8E93));

  // [HIG] Label / separator / background semantic colors
  static const label = (Color(0xFF000000), Color(0xFFFFFFFF));
  static const secondaryLabel = (Color(0x993C3C43), Color(0x99EBEBF5)); // 60%
  static const tertiaryLabel = (Color(0x4D3C3C43), Color(0x4DEBEBF5)); // 30%
  static const separator = (Color(0x4A3C3C43), Color(0x99545458)); // 29% / 60%
  static const systemBackground = (Color(0xFFFFFFFF), Color(0xFF000000));
  static const secondarySystemBackground = (Color(0xFFF2F2F7), Color(0xFF1C1C1E));
  static const tertiarySystemBackground = (Color(0xFFFFFFFF), Color(0xFF2C2C2E));
}

/// [Fluent] 品牌色（Communication Blue ramp）与中性色令牌。
abstract final class FluentColors {
  static const brandBackground = (Color(0xFF0F6CBD), Color(0xFF115EA3)); // brand80 / brand70
  static const brandForeground = (Color(0xFF0F6CBD), Color(0xFF479EF5)); // brand80 / brand100
  static const neutralBackground1 = (Color(0xFFFFFFFF), Color(0xFF292929));
  static const neutralBackground2 = (Color(0xFFFAFAFA), Color(0xFF1F1F1F));
  static const neutralForeground1 = (Color(0xFF242424), Color(0xFFFFFFFF));
  static const neutralForeground2 = (Color(0xFF424242), Color(0xFFD6D6D6));
  static const neutralStroke2 = (Color(0xFFE0E0E0), Color(0xFF525252));
}

Color pick((Color, Color) c, bool dark) => dark ? c.$2 : c.$1;

// ---------------------------------------------------------------- typography

/// 字体族：西文优先各平台系统 UI 字体，中文回退到免费 CJK 字体。
abstract final class FontTokens {
  /// [Fluent] Segoe UI Variable（Windows 11）；[HIG] SF Pro；[M3] Roboto。Linux 使用 Noto Sans。
  static String? get family {
    try {
      if (Platform.isWindows) return 'Segoe UI Variable Text';
      if (Platform.isMacOS || Platform.isIOS) return '.AppleSystemUIFont';
      if (Platform.isAndroid) return 'Roboto';
    } catch (_) {}
    return 'Noto Sans';
  }

  /// CJK 回退链：系统自带（微软雅黑 / 苹方）→ 免费开源/免费商用字体
  /// （HarmonyOS Sans SC、MiSans、Noto Sans CJK SC / 思源黑体）。
  static const cjkFallback = <String>[
    'Microsoft YaHei UI',
    'PingFang SC',
    'HarmonyOS Sans SC',
    'MiSans',
    'Noto Sans CJK SC',
    'Noto Sans SC',
    'Source Han Sans SC',
    'WenQuanYi Micro Hei',
    'sans-serif',
  ];

  static const mono = 'JetBrains Mono';
  static const monoFallback = ['Cascadia Code', 'SF Mono', 'Menlo', 'Consolas', 'Noto Sans Mono CJK SC', 'monospace'];
}

/// 字号 / 行高 / 字重。行高以像素给出，使用 height = lineHeight / size。
class TypeStyle {
  final double size, lineHeight;
  final FontWeight weight;
  final double tracking;
  const TypeStyle(this.size, this.lineHeight, this.weight, [this.tracking = 0]);
  TextStyle get style => TextStyle(fontSize: size, height: lineHeight / size, fontWeight: weight, letterSpacing: tracking);
}

/// [M3] Type scale（m3.material.io/styles/typography/type-scale-tokens）
abstract final class M3Type {
  static const displayLarge = TypeStyle(57, 64, FontWeight.w400, -0.25);
  static const displayMedium = TypeStyle(45, 52, FontWeight.w400);
  static const displaySmall = TypeStyle(36, 44, FontWeight.w400);
  static const headlineLarge = TypeStyle(32, 40, FontWeight.w400);
  static const headlineMedium = TypeStyle(28, 36, FontWeight.w400);
  static const headlineSmall = TypeStyle(24, 32, FontWeight.w400);
  static const titleLarge = TypeStyle(22, 28, FontWeight.w400);
  static const titleMedium = TypeStyle(16, 24, FontWeight.w500, 0.15);
  static const titleSmall = TypeStyle(14, 20, FontWeight.w500, 0.1);
  static const bodyLarge = TypeStyle(16, 24, FontWeight.w400, 0.5);
  static const bodyMedium = TypeStyle(14, 20, FontWeight.w400, 0.25);
  static const bodySmall = TypeStyle(12, 16, FontWeight.w400, 0.4);
  static const labelLarge = TypeStyle(14, 20, FontWeight.w500, 0.1);
  static const labelMedium = TypeStyle(12, 16, FontWeight.w500, 0.5);
  static const labelSmall = TypeStyle(11, 16, FontWeight.w500, 0.5);
}

/// [Fluent] Type ramp（Segoe UI Variable，Windows）
abstract final class FluentType {
  static const caption2 = TypeStyle(10, 14, FontWeight.w400);
  static const caption1 = TypeStyle(12, 16, FontWeight.w400);
  static const body1 = TypeStyle(14, 20, FontWeight.w400);
  static const body1Strong = TypeStyle(14, 20, FontWeight.w600);
  static const subtitle2 = TypeStyle(16, 22, FontWeight.w600);
  static const subtitle1 = TypeStyle(20, 28, FontWeight.w600);
  static const title3 = TypeStyle(24, 32, FontWeight.w600);
  static const title2 = TypeStyle(28, 36, FontWeight.w600);
  static const title1 = TypeStyle(32, 40, FontWeight.w600);
  static const largeTitle = TypeStyle(40, 52, FontWeight.w600);
  static const display = TypeStyle(68, 92, FontWeight.w600);
}

/// [HIG] Dynamic Type，默认 "Large" 档（iOS）。用于编辑器标题层级（与 Apple Notes / Notion 节奏一致）。
abstract final class HigType {
  static const largeTitle = TypeStyle(34, 41, FontWeight.w700, 0.4); // 页面标题（加粗变体）
  static const title1 = TypeStyle(28, 34, FontWeight.w700, 0.38); // H1
  static const title2 = TypeStyle(22, 28, FontWeight.w700, -0.26); // H2
  static const title3 = TypeStyle(20, 25, FontWeight.w600, -0.45); // H3
  static const headline = TypeStyle(17, 22, FontWeight.w600, -0.43);
  static const body = TypeStyle(17, 22, FontWeight.w400, -0.43);
  static const callout = TypeStyle(16, 21, FontWeight.w400, -0.31);
  static const subheadline = TypeStyle(15, 20, FontWeight.w400, -0.23);
  static const footnote = TypeStyle(13, 18, FontWeight.w400, -0.08);
  static const caption1 = TypeStyle(12, 16, FontWeight.w400);
  static const caption2 = TypeStyle(11, 13, FontWeight.w400, 0.06);
}

/// 编辑器使用的语义字号（桌面端正文 16 = [M3] bodyLarge；标题取 [HIG] title 层级）。
abstract final class EditorType {
  static const pageTitle = HigType.largeTitle;
  static const h1 = HigType.title1;
  static const h2 = HigType.title2;
  static const h3 = HigType.title3;
  static const body = TypeStyle(16, 26, FontWeight.w400); // [M3] bodyLarge 16，行高放宽到 1.6 适配中文
  static const code = TypeStyle(14, 21, FontWeight.w400);
}

// ---------------------------------------------------------------- spacing / radius

/// 4 点网格：[M3] 4dp baseline grid，[Fluent] spacing ramp（XXS 2 … XXXL 32）。
abstract final class Space {
  static const xxs = 2.0; // Fluent sizeXXS
  static const xs = 4.0; // Fluent XS / M3 1 unit
  static const s = 8.0; // Fluent S
  static const m = 12.0; // Fluent M
  static const l = 16.0; // Fluent L / M3 compact margin
  static const xl = 20.0; // Fluent XL
  static const xxl = 24.0; // Fluent XXL / M3 medium margin
  static const xxxl = 32.0; // Fluent XXXL
  static const page = 48.0; // 编辑器左右留白（Notion 96px 的半值，适配小窗）
}

/// 圆角：[M3] shape scale；Windows 上 [Fluent] corner radius。
abstract final class Radii {
  // [M3] shape corner tokens
  static const extraSmall = 4.0;
  static const small = 8.0;
  static const medium = 12.0;
  static const large = 16.0;
  static const extraLarge = 28.0;
  // [Fluent] borderRadius tokens
  static const fluentSmall = 2.0;
  static const fluentMedium = 4.0;
  static const fluentLarge = 8.0;
  static const fluentXLarge = 12.0;

  /// 控件（按钮、输入框、菜单项）
  static double get control => currentLanguage == DesignLanguage.fluent ? fluentMedium : small;

  /// 卡片 / 菜单
  static double get card => currentLanguage == DesignLanguage.fluent ? fluentLarge : medium;

  /// 浮层（快速切换器、对话框）。[M3] Dialog = extraLarge 28；[Fluent] Dialog = XLarge 12
  static double get dialog => currentLanguage == DesignLanguage.fluent ? fluentXLarge : extraLarge;

  /// 玻璃面板（侧边栏、内容区）：[HIG] Liquid Glass 使用大圆角连续曲线（superellipse），
  /// 与窗口圆角同心（concentric）：外框 large(16) + 内边距 → 22。
  static const glassPanel = 22.0;
}

// ---------------------------------------------------------------- elevation

/// [M3] elevation levels（dp）：0, 1, 3, 6, 8, 12
abstract final class Elevation {
  static const level0 = 0.0, level1 = 1.0, level2 = 3.0, level3 = 6.0, level4 = 8.0, level5 = 12.0;

  /// [Fluent] shadow16（浮层）：0 0 2px rgba(0,0,0,.12), 0 8px 16px rgba(0,0,0,.14)
  static List<BoxShadow> fluentShadow16(bool dark) => [
        BoxShadow(color: Color.fromRGBO(0, 0, 0, dark ? 0.24 : 0.12), blurRadius: 2),
        BoxShadow(color: Color.fromRGBO(0, 0, 0, dark ? 0.28 : 0.14), offset: const Offset(0, 8), blurRadius: 16),
      ];
}

// ---------------------------------------------------------------- materials

/// 玻璃材质参数。[HIG] Liquid Glass：regular（默认，自适应着色）与 clear（更通透）两种变体；
/// [Fluent] Acrylic：高斯模糊 + 色调层（tint opacity ~0.7–0.8）+ 亮度层；Mica 用于窗口底层。
abstract final class Materials {
  /// regular 变体：用于侧边栏、菜单等控件层
  static double tintRegular(bool dark) => dark ? 0.48 : 0.45;

  /// 内容面板（编辑器、列表）：需更高不透明度以满足 WCAG 4.5:1 正文对比度
  static double tintContent(bool dark) => dark ? 0.72 : 0.74;

  /// [Fluent] Acrylic 默认色调不透明度（Windows 上替换 regular）
  static const acrylicTint = 0.70;

  /// 模糊半径：[Fluent] Acrylic blur 30px（σ≈15）；[HIG] 未公开数值，取接近系统材质观感的 12–18
  static const blurRegular = 12.0, blurContent = 18.0, blurAcrylic = 15.0;
}

// ---------------------------------------------------------------- motion

/// [M3] Motion duration tokens（ms）
abstract final class Motion {
  static const short1 = Duration(milliseconds: 50);
  static const short2 = Duration(milliseconds: 100);
  static const short3 = Duration(milliseconds: 150);
  static const short4 = Duration(milliseconds: 200);
  static const medium1 = Duration(milliseconds: 250);
  static const medium2 = Duration(milliseconds: 300);
  static const medium3 = Duration(milliseconds: 350);
  static const medium4 = Duration(milliseconds: 400);
  static const long1 = Duration(milliseconds: 450);
  static const long2 = Duration(milliseconds: 500);
  // [Fluent] durationFast / Normal / Gentle
  static const fluentFast = Duration(milliseconds: 150);
  static const fluentNormal = Duration(milliseconds: 200);
  static const fluentGentle = Duration(milliseconds: 250);
}

/// 缓动曲线。
abstract final class MotionCurves {
  // [M3] easing tokens
  static const emphasized = Cubic(0.2, 0.0, 0.0, 1.0);
  static const emphasizedDecelerate = Cubic(0.05, 0.7, 0.1, 1.0);
  static const emphasizedAccelerate = Cubic(0.3, 0.0, 0.8, 0.15);
  static const standard = Cubic(0.2, 0.0, 0.0, 1.0);
  static const standardDecelerate = Cubic(0.0, 0.0, 0.0, 1.0);
  static const standardAccelerate = Cubic(0.3, 0.0, 1.0, 1.0);
  // [Fluent] curve tokens
  static const fluentDecelerateMid = Cubic(0.0, 0.0, 0.0, 1.0);
  static const fluentAccelerateMid = Cubic(1.0, 0.0, 1.0, 1.0);
  static const fluentEasyEase = Cubic(0.33, 0.0, 0.67, 1.0);

  /// 当前平台的"进入"曲线
  static Curve get enter => currentLanguage == DesignLanguage.fluent ? fluentDecelerateMid : emphasizedDecelerate;
  static Curve get exit => currentLanguage == DesignLanguage.fluent ? fluentAccelerateMid : emphasizedAccelerate;
}

/// [HIG] 弹簧动画：SwiftUI 默认 spring(response: 0.55, dampingFraction: 0.825)
/// 以及 .bouncy(response 0.5, extraBounce 0.3 → dampingFraction≈0.7)。
/// 换算：stiffness = (2π / response)²，damping = 4π·ζ / response（mass = 1）。
abstract final class Springs {
  static SpringDescription fromHig(double response, double dampingFraction) {
    final k = (2 * 3.141592653589793 / response);
    return SpringDescription(mass: 1, stiffness: k * k, damping: 2 * dampingFraction * k);
  }

  static final smooth = fromHig(0.55, 0.825); // 默认
  static final bouncy = fromHig(0.5, 0.7); // 菜单/弹窗出现
  static final snappy = fromHig(0.4, 0.85);
}

/// 把弹簧模拟包装成 Curve（时长取约 1.2×response 后进入稳态）。
class SpringCurve extends Curve {
  final SpringDescription spring;
  final double span; // 模拟秒数 ↔ t∈[0,1]
  const SpringCurve(this.spring, {this.span = 0.9});
  @override
  double transformInternal(double t) => SpringSimulation(spring, 0, 1, 0).x(t * span);
}
