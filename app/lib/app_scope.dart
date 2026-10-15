import 'package:flutter/widgets.dart';

import 'services/auth_api.dart';
import 'services/settings.dart';
import 'sync/sync_client.dart';

/// 全局依赖注入。
class AppServices {
  final SyncClient sync;
  final Settings settings;
  final AuthApi api;
  final Future<void> Function() logout;
  AppServices({required this.sync, required this.settings, required this.api, required this.logout});
}

class AppScope extends InheritedWidget {
  final AppServices services;
  const AppScope({super.key, required this.services, required super.child});

  static AppServices of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppScope>()!.services;

  @override
  bool updateShouldNotify(AppScope oldWidget) => services != oldWidget.services;
}
