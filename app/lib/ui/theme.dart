import 'package:flutter/material.dart';

import 'tokens.dart';

/// 由设计令牌生成主题。Liquid Glass 身份在所有平台一致（透明脚手架 + 玻璃面板），
/// 字体字阶 / 圆角 / 动效按平台切换：Windows → Fluent 2，其余 → Material 3。
ThemeData buildAppTheme(Brightness b, {DesignLanguage? language}) {
  final lang = language ?? currentLanguage;
  final dark = b == Brightness.dark;
  final fluent = lang == DesignLanguage.fluent;

  // 主色：Windows 用 [Fluent] brand；其他平台用 [HIG] systemBlue。
  // 其余角色由 [M3] 色调调色板（tonal palette）从主色派生，再用 [HIG] 语义色覆盖文字/分隔线/状态色。
  final primary = fluent ? pick(FluentColors.brandForeground, dark) : pick(HigColors.blue, dark);
  final base = ColorScheme.fromSeed(seedColor: primary, brightness: b, dynamicSchemeVariant: DynamicSchemeVariant.tonalSpot);
  final cs = base.copyWith(
    primary: primary,
    onPrimary: Colors.white,
    error: pick(HigColors.red, dark),
    tertiary: pick(HigColors.purple, dark),
    secondary: pick(HigColors.teal, dark),
    onSurface: fluent ? pick(FluentColors.neutralForeground1, dark) : (dark ? const Color(0xFFF2F2F7) : const Color(0xFF1C1C1E)),
    onSurfaceVariant: fluent ? pick(FluentColors.neutralForeground2, dark) : pick(HigColors.secondaryLabel, dark),
    outline: pick(HigColors.gray, dark),
    outlineVariant: fluent ? pick(FluentColors.neutralStroke2, dark) : pick(HigColors.separator, dark),
    surface: fluent ? pick(FluentColors.neutralBackground1, dark) : pick(HigColors.systemBackground, dark),
    surfaceContainerLowest: pick(HigColors.tertiarySystemBackground, dark),
    surfaceContainerLow: pick(HigColors.secondarySystemBackground, dark),
  );

  TextStyle t(TypeStyle s) => s.style;
  final scale = fluent
      ? TextTheme(
          displayLarge: t(FluentType.display),
          displayMedium: t(FluentType.largeTitle),
          displaySmall: t(FluentType.title1),
          headlineLarge: t(FluentType.title1),
          headlineMedium: t(FluentType.title2),
          headlineSmall: t(FluentType.title3),
          titleLarge: t(FluentType.subtitle1),
          titleMedium: t(FluentType.subtitle2),
          titleSmall: t(FluentType.body1Strong),
          bodyLarge: t(FluentType.body1),
          bodyMedium: t(FluentType.body1),
          bodySmall: t(FluentType.caption1),
          labelLarge: t(FluentType.body1Strong),
          labelMedium: t(FluentType.caption1),
          labelSmall: t(FluentType.caption2),
        )
      : TextTheme(
          displayLarge: t(M3Type.displayLarge),
          displayMedium: t(M3Type.displayMedium),
          displaySmall: t(M3Type.displaySmall),
          headlineLarge: t(M3Type.headlineLarge),
          headlineMedium: t(M3Type.headlineMedium),
          headlineSmall: t(M3Type.headlineSmall),
          titleLarge: t(M3Type.titleLarge),
          titleMedium: t(M3Type.titleMedium),
          titleSmall: t(M3Type.titleSmall),
          bodyLarge: t(M3Type.bodyLarge),
          bodyMedium: t(M3Type.bodyMedium),
          bodySmall: t(M3Type.bodySmall),
          labelLarge: t(M3Type.labelLarge),
          labelMedium: t(M3Type.labelMedium),
          labelSmall: t(M3Type.labelSmall),
        );
  final text = scale
      .apply(
        fontFamily: FontTokens.family,
        fontFamilyFallback: FontTokens.cjkFallback,
        bodyColor: cs.onSurface,
        displayColor: cs.onSurface,
      );

  final ctl = Radii.control, card = Radii.card;
  final glassSurface = (dark ? const Color(0xFF1C1C1E) : Colors.white);
  final hairline = Colors.white.withValues(alpha: dark ? 0.08 : 0.6);

  return ThemeData(
    useMaterial3: true,
    colorScheme: cs,
    fontFamily: FontTokens.family,
    fontFamilyFallback: FontTokens.cjkFallback,
    textTheme: text,
    visualDensity: fluent ? VisualDensity.compact : VisualDensity.standard,
    scaffoldBackgroundColor: Colors.transparent,
    canvasColor: Colors.transparent,
    splashFactory: fluent ? NoSplash.splashFactory : InkSparkle.splashFactory,
    appBarTheme: AppBarTheme(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: Elevation.level0,
      elevation: Elevation.level0,
      titleTextStyle: text.titleMedium?.copyWith(fontWeight: FontWeight.w600),
    ),
    dividerTheme: DividerThemeData(color: cs.outlineVariant, space: 1, thickness: 0.5),
    cardTheme: CardThemeData(
      elevation: Elevation.level0,
      color: glassSurface.withValues(alpha: dark ? 0.55 : 0.62),
      surfaceTintColor: Colors.transparent,
      margin: const EdgeInsets.symmetric(horizontal: Space.m, vertical: Space.xs),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(card), side: BorderSide(color: hairline)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: (dark ? Colors.black : Colors.white).withValues(alpha: 0.35),
      contentPadding: const EdgeInsets.symmetric(horizontal: Space.m, vertical: Space.m),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(ctl), borderSide: BorderSide(color: cs.outlineVariant)),
      // 只设置 border：编辑器的 InputDecoration.collapsed（border: none）因此不会继承描边
    ),
    filledButtonTheme: FilledButtonThemeData(style: FilledButton.styleFrom(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(fluent ? ctl : 100)))),
    outlinedButtonTheme: OutlinedButtonThemeData(style: OutlinedButton.styleFrom(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(fluent ? ctl : 100)))),
    chipTheme: ChipThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(fluent ? ctl : Radii.small)),
      backgroundColor: glassSurface.withValues(alpha: 0.4),
      selectedColor: cs.primary.withValues(alpha: 0.18),
      side: BorderSide(color: hairline),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: glassSurface.withValues(alpha: 0.9),
      surfaceTintColor: Colors.transparent,
      elevation: fluent ? Elevation.level4 : Elevation.level2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(card), side: BorderSide(color: hairline)),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: glassSurface.withValues(alpha: 0.88),
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.dialog)),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: glassSurface.withValues(alpha: 0.9),
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(Radii.extraLarge))),
    ),
    drawerTheme: DrawerThemeData(backgroundColor: glassSurface.withValues(alpha: 0.82)),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(ctl)),
    ),
    tooltipTheme: TooltipThemeData(
      waitDuration: Motion.long2,
      textStyle: text.bodySmall?.copyWith(color: Colors.white),
      decoration: BoxDecoration(color: dark ? const Color(0xFF3A3A3C) : const Color(0xFF1C1C1E), borderRadius: BorderRadius.circular(Radii.extraSmall)),
    ),
    pageTransitionsTheme: const PageTransitionsTheme(builders: {
      TargetPlatform.android: PredictiveBackPageTransitionsBuilder(),
      TargetPlatform.linux: FadeForwardsPageTransitionsBuilder(),
      TargetPlatform.windows: FadeForwardsPageTransitionsBuilder(),
    }),
  );
}
