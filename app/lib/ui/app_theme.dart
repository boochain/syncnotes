import 'package:flutter/material.dart';

import 'tokens.dart';

class AppLook {
  const AppLook({required this.seed, required this.bg, required this.side, this.forced});
  final Color seed;
  final Color bg;
  final Color side;
  final Brightness? forced;
}

AppLook lookFor(String name, Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final bg = dark ? Tokens.darkBg : Tokens.lightBg;
  final side = dark ? Tokens.darkSide : Tokens.lightSide;
  return switch (name) {
    'ocean' => AppLook(seed: const Color(0xFF0F6E8C), bg: dark ? const Color(0xFF102228) : const Color(0xFFF3FAFB), side: side),
    'dusk' => AppLook(seed: const Color(0xFF6B4C9A), bg: dark ? const Color(0xFF1A1524) : const Color(0xFFF8F5FB), side: side),
    'paper' => const AppLook(seed: Color(0xFF8A5A2B), bg: Color(0xFFFFFBF5), side: Color(0xFFF6F1E8), forced: Brightness.light),
    'ink' => const AppLook(seed: Tokens.accentDark, bg: Tokens.darkBg, side: Tokens.darkSide, forced: Brightness.dark),
    _ => AppLook(seed: dark ? Tokens.accentDark : Tokens.accent, bg: bg, side: side),
  };
}

ThemeData appTheme(AppLook look, Brightness brightness, double cardOpacity) {
  final dark = brightness == Brightness.dark;
  final scheme = ColorScheme.fromSeed(seedColor: look.seed, brightness: brightness);
  final text = dark ? Tokens.darkText : Tokens.lightText;
  final muted = dark ? Tokens.darkText2 : Tokens.lightText2;
  final fill = dark ? Tokens.darkFill : Tokens.lightFill;
  final line = dark ? Tokens.darkLine : Tokens.lightLine;
  final base = ThemeData(
    useMaterial3: true,
    colorScheme: scheme.copyWith(surface: look.bg, primary: dark ? Tokens.accentDark : Tokens.accent),
    scaffoldBackgroundColor: look.bg,
    dividerColor: line,
    splashFactory: NoSplash.splashFactory,
  );
  return base.copyWith(
    textTheme: base.textTheme.apply(bodyColor: text, displayColor: text).copyWith(
          bodyMedium: TextStyle(fontSize: 14, height: 20 / 14, color: text),
          bodySmall: TextStyle(fontSize: 12, height: 16 / 12, color: muted),
          titleMedium: TextStyle(fontSize: 16, height: 22 / 16, fontWeight: FontWeight.w600, color: text),
          titleLarge: const TextStyle(fontSize: 20, height: 28 / 20, fontWeight: FontWeight.w600),
        ),
    cardTheme: CardThemeData(color: scheme.surface.withValues(alpha: cardOpacity), elevation: 0, margin: EdgeInsets.zero),
    appBarTheme: AppBarTheme(
      elevation: 0,
      scrolledUnderElevation: 0,
      toolbarHeight: Tokens.bar,
      backgroundColor: look.bg,
      foregroundColor: text,
      titleTextStyle: TextStyle(fontSize: 16, height: 22 / 16, fontWeight: FontWeight.w600, color: text),
    ),
    listTileTheme: const ListTileThemeData(dense: true, contentPadding: EdgeInsets.symmetric(horizontal: 12)),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: fill,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(minimumSize: const Size(0, Tokens.input), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
    ),
    navigationRailTheme: NavigationRailThemeData(backgroundColor: look.side),
    pageTransitionsTheme: const PageTransitionsTheme(builders: {
      TargetPlatform.android: FadeUpwardsPageTransitionsBuilder(),
      TargetPlatform.iOS: FadeUpwardsPageTransitionsBuilder(),
      TargetPlatform.linux: FadeUpwardsPageTransitionsBuilder(),
      TargetPlatform.macOS: FadeUpwardsPageTransitionsBuilder(),
      TargetPlatform.windows: FadeUpwardsPageTransitionsBuilder(),
      TargetPlatform.fuchsia: FadeUpwardsPageTransitionsBuilder(),
    }),
  );
}
