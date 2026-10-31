import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'api.dart';
import 'desktop.dart';
import 'home_page.dart';
import 'login_page.dart';
import 'scope.dart';
import 'session.dart';
import 'settings_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final store = await SettingsStore.load();
  final dir = await getApplicationSupportDirectory();
  final session = Session(prefs: store, api: SyncApi(), supportDir: dir);
  if (isDesktop && !Platform.environment.containsKey('FLUTTER_TEST')) {
    try {
      await Desk.init(expanded: store.getBool('window_expanded') ?? true);
    } catch (e) {
      debugPrint('desktop: $e');
    }
  }
  await session.restore();
  runApp(SyncApp(session: session));
}

class SyncApp extends StatelessWidget {
  const SyncApp({super.key, required this.session});
  final Session session;

  @override
  Widget build(BuildContext context) {
    return Scope(
      session: session,
      child: ListenableBuilder(
        listenable: session,
        builder: (context, _) {
          final mode = switch (session.themeMode) {
            'light' => ThemeMode.light,
            'dark' => ThemeMode.dark,
            _ => ThemeMode.system,
          };
          return MaterialApp(
            title: 'SyncNotes',
            theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF3D5AFE)), useMaterial3: true),
            darkTheme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF3D5AFE), brightness: Brightness.dark), useMaterial3: true),
            themeMode: mode,
            home: session.signedIn ? const HomePage() : LoginPage(initialServer: session.server ?? ''),
          );
        },
      ),
    );
  }
}
