import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'tokens.dart';

/// 主题：以 Apple HIG 为基础（系统色、SF 字阶、Liquid Glass 材质、连续圆角、弹簧动效），
/// 融合 Material 3 的色调调色板（容器色派生）与状态层、Fluent 2 的 4px 间距与 Acrylic 色调（详见 design-system.md）。
/// [language] 仅为兼容旧测试保留；所有平台使用同一套设计。
ThemeData buildAppTheme(Brightness b, {DesignLanguage? language}) {
  final dark = b == Brightness.dark;
  final desktop = isDesktopPlatform;

  // [HIG] 系统色 + 语义色；[M3] 从 systemBlue 派生 tonal palette，补全 container / inverse 等角色
  final primary = pick(HigColors.blue, dark);
  final base = ColorScheme.fromSeed(seedColor: primary, brightness: b, dynamicSchemeVariant: DynamicSchemeVariant.neutral);
  final cs = base.copyWith(
    primary: primary,
    onPrimary: Colors.white,
    secondary: pick(HigColors.indigo, dark),
    tertiary: pick(HigColors.purple, dark),
    error: pick(HigColors.red, dark),
    onSurface: dark ? const Color(0xFFF5F5F7) : const Color(0xFF1D1D1F), // Apple 官网正文色
    onSurfaceVariant: pick(HigColors.secondaryLabel, dark),
    outline: pick(HigColors.gray, dark),
    outlineVariant: pick(HigColors.separator, dark),
    surface: pick(HigColors.systemBackground, dark),
    surfaceContainerLowest: pick(HigColors.tertiarySystemBackground, dark),
    surfaceContainerLow: pick(HigColors.secondarySystemBackground, dark),
    surfaceContainer: dark ? const Color(0xFF2C2C2E) : const Color(0xFFE5E5EA), // systemGray5
    surfaceContainerHigh: dark ? const Color(0xFF3A3A3C) : const Color(0xFFD1D1D6), // systemGray4
    surfaceContainerHighest: dark ? const Color(0xFF48484A) : const Color(0xFFC7C7CC), // systemGray3
  );

  // [HIG] 字阶：触屏用 Dynamic Type "Large"，桌面用 "Small"
  TextStyle t(TypeStyle s) => s.style;
  final T = desktop
      ? (
          lt: HigTypeSmall.largeTitle, t1: HigTypeSmall.title1, t2: HigTypeSmall.title2, t3: HigTypeSmall.title3,
          hl: HigTypeSmall.headline, body: HigTypeSmall.body, callout: HigTypeSmall.callout,
          sub: HigTypeSmall.subheadline, foot: HigTypeSmall.footnote, cap: HigTypeSmall.caption1,
        )
      : (
          lt: HigType.largeTitle, t1: HigType.title1, t2: HigType.title2, t3: HigType.title3,
          hl: HigType.headline, body: HigType.body, callout: HigType.callout,
          sub: HigType.subheadline, foot: HigType.footnote, cap: HigType.caption1,
        );
  final scale = TextTheme(
    displayLarge: t(T.lt),
    displayMedium: t(T.lt),
    displaySmall: t(T.t1),
    headlineLarge: t(T.t1),
    headlineMedium: t(T.t2),
    headlineSmall: t(T.t3),
    titleLarge: t(T.t3),
    titleMedium: t(T.hl),
    titleSmall: t(T.sub).copyWith(fontWeight: FontWeight.w600),
    bodyLarge: t(T.body),
    bodyMedium: t(T.callout),
    bodySmall: t(T.foot),
    labelLarge: t(T.callout).copyWith(fontWeight: FontWeight.w500),
    labelMedium: t(T.foot).copyWith(fontWeight: FontWeight.w500),
    labelSmall: t(T.cap).copyWith(fontWeight: FontWeight.w500),
  );
  final text = scale.apply(
    fontFamily: FontTokens.family,
    fontFamilyFallback: FontTokens.cjkFallback,
    bodyColor: cs.onSurface,
    displayColor: cs.onSurface,
  );

  final ctl = Radii.control, card = Radii.card;
  final glassSurface = dark ? const Color(0xFF1C1C1E) : Colors.white;
  final hairline = dark ? Colors.white.withValues(alpha: 0.10) : Colors.black.withValues(alpha: 0.06);

  return ThemeData(
    useMaterial3: true,
    colorScheme: cs,
    fontFamily: FontTokens.family,
    fontFamilyFallback: FontTokens.cjkFallback,
    textTheme: text,
    visualDensity: desktop ? VisualDensity.compact : VisualDensity.standard,
    scaffoldBackgroundColor: Colors.transparent,
    canvasColor: Colors.transparent,
    // [HIG] 无涟漪：按压用高亮/透明度反馈；[M3] state layer（hover 8% / pressed 12%）用于悬停高亮
    splashFactory: NoSplash.splashFactory,
    hoverColor: cs.onSurface.withValues(alpha: 0.05),
    highlightColor: cs.onSurface.withValues(alpha: 0.08),
    focusColor: cs.primary.withValues(alpha: 0.12),
    cupertinoOverrideTheme: CupertinoThemeData(primaryColor: primary, brightness: b),
    iconTheme: IconThemeData(color: cs.onSurfaceVariant, size: desktop ? 18 : 22),
    appBarTheme: AppBarTheme(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: 0,
      elevation: 0,
      centerTitle: false,
      iconTheme: IconThemeData(color: cs.onSurfaceVariant, size: desktop ? 18 : 22),
      titleTextStyle: text.titleMedium,
      toolbarHeight: desktop ? 48 : 52,
    ),
    dividerTheme: DividerThemeData(color: cs.outlineVariant, space: 1, thickness: 0.5),
    listTileTheme: ListTileThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(ctl)),
      titleTextStyle: text.bodyLarge,
      subtitleTextStyle: text.bodySmall?.copyWith(color: cs.onSurfaceVariant),
      iconColor: cs.onSurfaceVariant,
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      color: glassSurface.withValues(alpha: dark ? 0.50 : 0.70),
      surfaceTintColor: Colors.transparent,
      margin: const EdgeInsets.symmetric(horizontal: Space.m, vertical: Space.xs),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(card), side: BorderSide(color: hairline)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      // [HIG] 文本框：tertiarySystemFill 底、无描边
      fillColor: dark ? const Color(0x3D767680) : const Color(0x1F767680),
      contentPadding: const EdgeInsets.symmetric(horizontal: Space.m, vertical: Space.s + 2),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(ctl + 2), borderSide: BorderSide.none),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(ctl + 2)),
        textStyle: text.labelLarge?.copyWith(fontWeight: FontWeight.w600),
      ),
    ),
    textButtonTheme: TextButtonThemeData(style: TextButton.styleFrom(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(ctl)))),
    outlinedButtonTheme: OutlinedButtonThemeData(style: OutlinedButton.styleFrom(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(ctl + 2)))),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: SegmentedButton.styleFrom(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(ctl + 1)),
        side: BorderSide(color: hairline),
        selectedBackgroundColor: glassSurface,
        backgroundColor: dark ? const Color(0x3D767680) : const Color(0x1F767680),
      ),
    ),
    chipTheme: ChipThemeData(
      shape: const StadiumBorder(),
      backgroundColor: dark ? const Color(0x3D767680) : const Color(0x14767680),
      selectedColor: primary.withValues(alpha: dark ? 0.30 : 0.14),
      side: BorderSide.none,
      labelStyle: text.labelLarge,
      padding: const EdgeInsets.symmetric(horizontal: Space.xs),
    ),
    switchTheme: SwitchThemeData(
      // [HIG] 开关：开启为 systemGreen；Material 开关形状由 adaptive 在 Apple 平台替换
      trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? pick(HigColors.green, dark) : (dark ? const Color(0x5C787880) : const Color(0x33787880))), // HIG systemFill
      thumbColor: const WidgetStatePropertyAll(Colors.white),
      trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
      thumbIcon: const WidgetStatePropertyAll(null),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: glassSurface.withValues(alpha: 0.92),
      surfaceTintColor: Colors.transparent,
      elevation: Elevation.level3,
      shadowColor: Colors.black.withValues(alpha: 0.25),
      textStyle: text.bodyMedium,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(card), side: BorderSide(color: hairline)),
    ),
    menuTheme: MenuThemeData(
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(glassSurface.withValues(alpha: 0.92)),
        shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.circular(card))),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: glassSurface.withValues(alpha: 0.92),
      surfaceTintColor: Colors.transparent,
      titleTextStyle: text.titleMedium,
      contentTextStyle: text.bodyMedium,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.dialog)),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: glassSurface.withValues(alpha: 0.94),
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(Radii.medium))),
    ),
    drawerTheme: DrawerThemeData(backgroundColor: glassSurface.withValues(alpha: 0.82)),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: dark ? const Color(0xFF3A3A3C) : const Color(0xFF1D1D1F),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.medium)),
    ),
    tooltipTheme: TooltipThemeData(
      waitDuration: Motion.long2,
      textStyle: text.labelSmall?.copyWith(color: Colors.white),
      decoration: BoxDecoration(color: dark ? const Color(0xFF3A3A3C) : const Color(0xE61D1D1F), borderRadius: BorderRadius.circular(Radii.small - 2)),
    ),
    scrollbarTheme: ScrollbarThemeData(
      thickness: const WidgetStatePropertyAll(6),
      radius: const Radius.circular(3),
      thumbColor: WidgetStatePropertyAll(cs.onSurface.withValues(alpha: 0.25)),
    ),
    pageTransitionsTheme: const PageTransitionsTheme(builders: {
      // [HIG] 横向推入；Android 保留 [M3] 预测性返回手势（系统级交互，明显更好）
      TargetPlatform.android: PredictiveBackPageTransitionsBuilder(),
      TargetPlatform.linux: CupertinoPageTransitionsBuilder(),
      TargetPlatform.windows: CupertinoPageTransitionsBuilder(),
      TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
      TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
    }),
  );
}
