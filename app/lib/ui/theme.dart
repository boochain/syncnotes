import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'ds.dart';
import 'tokens.dart';

/// v0.4 主题：所有组件都从 ds.dart 的同一套调色板 / 字阶 / 高度 / 圆角取值。
/// [language] 仅为兼容旧测试保留；所有平台使用同一套设计。
ThemeData buildAppTheme(Brightness b, {DesignLanguage? language}) {
  final dark = b == Brightness.dark;
  // 触屏平台（Android / iOS）：按下水波纹反馈（Material 3）；桌面用悬停高亮，不要水波纹
  final touch = defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS;
  final c = dark ? AppColors.dark : AppColors.light;

  final cs = ColorScheme(
    brightness: b,
    primary: c.accent,
    onPrimary: Colors.white,
    primaryContainer: c.accent.withValues(alpha: 0.14),
    onPrimaryContainer: c.accent,
    secondary: c.text2,
    onSecondary: c.bg,
    secondaryContainer: c.selected,
    onSecondaryContainer: c.text,
    tertiary: c.text2,
    onTertiary: c.bg,
    error: c.danger,
    onError: Colors.white,
    surface: c.bg,
    onSurface: c.text,
    onSurfaceVariant: c.text2,
    outline: c.text3,
    outlineVariant: c.separator,
    surfaceContainerLowest: c.bg,
    surfaceContainerLow: c.sidebar,
    surfaceContainer: c.fill,
    surfaceContainerHigh: c.fill,
    surfaceContainerHighest: c.fill,
    inverseSurface: c.text,
    onInverseSurface: c.bg,
    shadow: Colors.black,
    scrim: Colors.black,
  );

  TextStyle t(TypeStyle s, [Color? color]) => s.style.copyWith(color: color ?? c.text);
  // Material 文本角色全部映射到 5 级字阶上，任何组件都不会用到字阶之外的字号
  final text = TextTheme(
    displayLarge: t(AppText.headline),
    displayMedium: t(AppText.headline),
    displaySmall: t(AppText.headline),
    headlineLarge: t(AppText.headline),
    headlineMedium: t(AppText.headline),
    headlineSmall: t(AppText.headline),
    titleLarge: t(AppText.title),
    titleMedium: t(AppText.title),
    titleSmall: t(AppText.bodyStrong),
    bodyLarge: t(AppText.body),
    bodyMedium: t(AppText.body),
    bodySmall: t(AppText.caption, c.text2),
    labelLarge: t(AppText.bodyStrong),
    labelMedium: t(AppText.caption),
    labelSmall: t(AppText.caption),
  ).apply(fontFamily: FontTokens.family, fontFamilyFallback: FontTokens.cjkFallback);

  final rS = BorderRadius.circular(AppRadius.s), rM = BorderRadius.circular(AppRadius.m), rL = BorderRadius.circular(AppRadius.l);
  final hairline = BorderSide(color: c.separator, width: 1);
  ButtonStyle sized(ButtonStyle s, double h) => s.copyWith(
        minimumSize: WidgetStatePropertyAll(Size(h, h)),
        fixedSize: WidgetStatePropertyAll(Size.fromHeight(h)),
        padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: Gap.l)),
        shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: rM)),
        textStyle: WidgetStatePropertyAll(text.labelLarge),
        visualDensity: VisualDensity.standard,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      );

  return ThemeData(
    useMaterial3: true,
    brightness: b,
    colorScheme: cs,
    extensions: [c],
    fontFamily: FontTokens.family,
    fontFamilyFallback: FontTokens.cjkFallback,
    textTheme: text,
    primaryTextTheme: text,
    visualDensity: VisualDensity.standard,
    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    scaffoldBackgroundColor: c.bg,
    canvasColor: c.bg,
    cardColor: c.bg,
    dividerColor: c.separator,
    splashFactory: touch ? InkRipple.splashFactory : NoSplash.splashFactory,
    hoverColor: c.hover,
    highlightColor: c.selected,
    focusColor: c.accent.withValues(alpha: 0.12),
    cupertinoOverrideTheme: CupertinoThemeData(primaryColor: c.accent, brightness: b),
    iconTheme: IconThemeData(color: c.text2, size: Sizes.iconSm),
    appBarTheme: AppBarTheme(
      backgroundColor: c.bg,
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: 0,
      elevation: 0,
      centerTitle: false,
      titleSpacing: Gap.l,
      iconTheme: IconThemeData(color: c.text2, size: Sizes.iconMd),
      actionsIconTheme: IconThemeData(color: c.text2, size: Sizes.iconMd),
      titleTextStyle: text.titleMedium,
      toolbarHeight: Sizes.bar,
      shape: Border(bottom: hairline),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        fixedSize: const Size.square(Sizes.control),
        minimumSize: const Size.square(Sizes.control),
        padding: EdgeInsets.zero,
        iconSize: Sizes.iconMd,
        foregroundColor: c.text2,
        shape: RoundedRectangleBorder(borderRadius: rS),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    ),
    dividerTheme: DividerThemeData(color: c.separator, space: 1, thickness: 1),
    listTileTheme: ListTileThemeData(
      shape: RoundedRectangleBorder(borderRadius: rS),
      titleTextStyle: text.bodyMedium,
      subtitleTextStyle: text.bodySmall,
      leadingAndTrailingTextStyle: text.bodySmall,
      iconColor: c.text2,
      minLeadingWidth: Sizes.iconMd,
      minVerticalPadding: Gap.m,
      horizontalTitleGap: Gap.l,
      contentPadding: const EdgeInsets.symmetric(horizontal: Gap.l),
      visualDensity: VisualDensity.standard,
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      color: c.bg,
      surfaceTintColor: Colors.transparent,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: rL, side: hairline),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: c.fill,
      isDense: true,
      hintStyle: text.bodyMedium?.copyWith(color: c.text3),
      labelStyle: text.bodyMedium?.copyWith(color: c.text2),
      contentPadding: const EdgeInsets.symmetric(horizontal: Gap.l, vertical: (Sizes.input - 20) / 2),
      border: OutlineInputBorder(borderRadius: rM, borderSide: BorderSide.none),
      enabledBorder: OutlineInputBorder(borderRadius: rM, borderSide: BorderSide.none),
      focusedBorder: OutlineInputBorder(borderRadius: rM, borderSide: BorderSide(color: c.accent, width: 1.5)),
      errorBorder: OutlineInputBorder(borderRadius: rM, borderSide: BorderSide(color: c.danger)),
    ),
    filledButtonTheme: FilledButtonThemeData(style: sized(FilledButton.styleFrom(backgroundColor: c.accent, foregroundColor: Colors.white), Sizes.input)),
    textButtonTheme: TextButtonThemeData(style: sized(TextButton.styleFrom(foregroundColor: c.accent), Sizes.control)),
    outlinedButtonTheme: OutlinedButtonThemeData(style: sized(OutlinedButton.styleFrom(foregroundColor: c.text, side: hairline), Sizes.input)),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        fixedSize: const WidgetStatePropertyAll(Size.fromHeight(Sizes.control)),
        minimumSize: const WidgetStatePropertyAll(Size(0, Sizes.control)),
        visualDensity: VisualDensity.standard,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        textStyle: WidgetStatePropertyAll(text.bodyMedium),
        iconSize: const WidgetStatePropertyAll(Sizes.iconSm),
        shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: rM)),
        side: WidgetStatePropertyAll(hairline),
        foregroundColor: WidgetStatePropertyAll(c.text),
        backgroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? c.selected : Colors.transparent),
      ),
    ),
    chipTheme: ChipThemeData(
      shape: RoundedRectangleBorder(borderRadius: rS),
      backgroundColor: Colors.transparent,
      selectedColor: c.selected,
      side: BorderSide(color: c.separator),
      labelStyle: text.bodyMedium?.copyWith(color: c.text),
      padding: const EdgeInsets.symmetric(horizontal: Gap.xs),
      showCheckmark: false,
    ),
    checkboxTheme: CheckboxThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.xs)),
      side: BorderSide(color: c.text3, width: 1.5),
      fillColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? c.accent : Colors.transparent),
      checkColor: const WidgetStatePropertyAll(Colors.white),
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    ),
    switchTheme: SwitchThemeData(
      // [HIG] 开关：开启 systemGreen；关闭 systemFill
      trackColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? c.success : (dark ? const Color(0x5C787880) : const Color(0x33787880))),
      thumbColor: const WidgetStatePropertyAll(Colors.white),
      trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
      thumbIcon: const WidgetStatePropertyAll(null),
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    ),
    radioTheme: RadioThemeData(fillColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? c.accent : c.text3)),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: c.accent, linearTrackColor: c.fill, circularTrackColor: Colors.transparent),
    popupMenuTheme: PopupMenuThemeData(
      color: c.elevated,
      surfaceTintColor: Colors.transparent,
      elevation: 8,
      shadowColor: Colors.black.withValues(alpha: 0.3),
      textStyle: text.bodyMedium,
      labelTextStyle: WidgetStatePropertyAll(text.bodyMedium),
      menuPadding: const EdgeInsets.all(Gap.xs),
      shape: RoundedRectangleBorder(borderRadius: rL, side: hairline),
    ),
    menuTheme: MenuThemeData(
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(c.elevated),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        padding: const WidgetStatePropertyAll(EdgeInsets.all(Gap.xs)),
        shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: rL, side: hairline)),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: c.elevated,
      surfaceTintColor: Colors.transparent,
      elevation: 12,
      titleTextStyle: text.titleMedium,
      contentTextStyle: text.bodyMedium,
      insetPadding: const EdgeInsets.symmetric(horizontal: Gap.xl, vertical: Gap.x3),
      actionsPadding: const EdgeInsets.fromLTRB(Gap.x3, 0, Gap.x3, Gap.xxl),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.xl), side: hairline),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: c.elevated,
      surfaceTintColor: Colors.transparent,
      showDragHandle: true,
      dragHandleColor: c.text3,
      dragHandleSize: const Size(36, 5),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.xl))),
    ),
    drawerTheme: DrawerThemeData(backgroundColor: c.sidebar, surfaceTintColor: Colors.transparent, width: 300, shape: const RoundedRectangleBorder()),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: dark ? c.elevated : c.text,
      contentTextStyle: text.bodyMedium?.copyWith(color: dark ? c.text : c.bg),
      actionTextColor: dark ? c.accent : const Color(0xFF64D2FF),
      elevation: 6,
      shape: RoundedRectangleBorder(borderRadius: rM),
      insetPadding: const EdgeInsets.all(Gap.l),
    ),
    tooltipTheme: TooltipThemeData(
      waitDuration: Motion.long2,
      textStyle: text.labelSmall?.copyWith(color: dark ? c.text : Colors.white),
      padding: const EdgeInsets.symmetric(horizontal: Gap.m, vertical: Gap.xs),
      decoration: BoxDecoration(
        color: dark ? const Color(0xFF3A3A3C) : const Color(0xE61D1D1F),
        borderRadius: BorderRadius.circular(AppRadius.s),
      ),
    ),
    scrollbarTheme: ScrollbarThemeData(
      thickness: const WidgetStatePropertyAll(6),
      radius: const Radius.circular(3),
      thumbColor: WidgetStatePropertyAll(c.text.withValues(alpha: 0.2)),
    ),
    textSelectionTheme: TextSelectionThemeData(cursorColor: c.accent, selectionColor: c.accent.withValues(alpha: 0.25), selectionHandleColor: c.accent),
    pageTransitionsTheme: const PageTransitionsTheme(builders: {
      TargetPlatform.android: PredictiveBackPageTransitionsBuilder(),
      TargetPlatform.linux: CupertinoPageTransitionsBuilder(),
      TargetPlatform.windows: CupertinoPageTransitionsBuilder(),
      TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
      TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
    }),
  );
}

/// 浮层统一外观（菜单、斜杠菜单、快速查找、格式工具栏）：elevated 纯色 + 细边 + 阴影
BoxDecoration floatingDecoration(BuildContext context, {double radius = AppRadius.l}) {
  final c = AppColors.of(context);
  final dark = Theme.of(context).brightness == Brightness.dark;
  return BoxDecoration(
    color: c.elevated,
    borderRadius: BorderRadius.circular(radius),
    border: Border.all(color: c.separator),
    boxShadow: [
      BoxShadow(color: Colors.black.withValues(alpha: dark ? 0.45 : 0.12), blurRadius: 24, offset: const Offset(0, 8)),
      BoxShadow(color: Colors.black.withValues(alpha: dark ? 0.30 : 0.05), blurRadius: 2),
    ],
  );
}
