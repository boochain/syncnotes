// 截图入口（不随应用发布）：flutter build linux -t tool/screenshot_recovery.dart
// SHOT=forgot|code  THEME=light|dark
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:syncnotes/services/auth_api.dart';
import 'package:syncnotes/ui/recovery_ui.dart';
import 'package:syncnotes/ui/theme.dart';

void main() {
  final shot = Platform.environment['SHOT'] ?? 'forgot';
  final dark = Platform.environment['THEME'] == 'dark';
  runApp(MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: buildAppTheme(Brightness.light),
    darkTheme: buildAppTheme(Brightness.dark),
    themeMode: dark ? ThemeMode.dark : ThemeMode.light,
    locale: const Locale('zh', 'CN'),
    supportedLocales: const [Locale('zh', 'CN')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    home: shot == 'code'
        ? Builder(builder: (c) {
            WidgetsBinding.instance.addPostFrameCallback((_) =>
                showRecoveryCodeDialog(c, code: 'K7QXM-2RTPA-W5NZC-H3FJD', username: 'bill', server: '192.168.1.10:7700'));
            return Scaffold(backgroundColor: Theme.of(c).scaffoldBackgroundColor);
          })
        : ForgotPasswordPage(api: AuthApi(), server: '192.168.1.10:7700', username: 'bill', deviceId: 'shot'),
  ));
}
