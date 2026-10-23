import 'package:flutter/material.dart';

import 'services/auth_api.dart';
import 'services/settings.dart';
import 'services/transfer_queue.dart';
import 'sync/sync_client.dart';

/// 全局依赖注入。
class AppServices {
  final SyncClient sync;
  final Settings settings;
  final AuthApi api;
  final Future<void> Function() logout;
  final ValueNotifier<ThemeMode> themeMode;
  final TransferQueue transfers;

  factory AppServices({
    required SyncClient sync,
    required Settings settings,
    required AuthApi api,
    required Future<void> Function() logout,
    ValueNotifier<ThemeMode>? themeMode,
    TransferQueue? transfers,
  }) {
    return AppServices._(
      sync: sync,
      settings: settings,
      api: api,
      logout: logout,
      themeMode: themeMode ?? ValueNotifier(ThemeMode.system),
      transfers: transfers ?? TransferQueue(api: api, settings: settings),
    );
  }

  AppServices._({
    required this.sync,
    required this.settings,
    required this.api,
    required this.logout,
    required this.themeMode,
    required this.transfers,
  });

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
