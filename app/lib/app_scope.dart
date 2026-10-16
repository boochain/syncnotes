import 'package:flutter/material.dart';

import 'services/auth_api.dart';
import 'services/settings.dart';
import 'sync/sync_client.dart';

/// 全局依赖注入。
class AppServices {
  final SyncClient sync;
  final Settings settings;
  final AuthApi api;
  final Future<void> Function() logout;
  final ValueNotifier<ThemeMode> themeMode;
  AppServices({required this.sync, required this.settings, required this.api, required this.logout, ValueNotifier<ThemeMode>? themeMode})
      : themeMode = themeMode ?? ValueNotifier(ThemeMode.system);

  static ThemeMode parseTheme(String s) => switch (s) { 'light' => ThemeMode.light, 'dark' => ThemeMode.dark, _ => ThemeMode.system };
}

class AppScope extends InheritedWidget {
  final AppServices services;
  const AppScope({super.key, required this.services, required super.child});

  static AppServices of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppScope>()!.services;

  @override
  bool updateShouldNotify(AppScope oldWidget) => services != oldWidget.services;
}
