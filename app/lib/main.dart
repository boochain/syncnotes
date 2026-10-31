import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'api.dart';
import 'desktop.dart';
import 'device.dart';
import 'home_page.dart';
import 'lock_page.dart';
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

class SyncApp extends StatefulWidget {
  const SyncApp({super.key, required this.session});
  final Session session;

  @override
  State<SyncApp> createState() => _SyncAppState();
}

class _SyncAppState extends State<SyncApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (!Platform.environment.containsKey('FLUTTER_TEST')) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _boot());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
      widget.session.lockIfNeeded();
    }
  }

  Future<void> _boot() async {
    if (Platform.isAndroid) {
      Device.share.setMethodCallHandler((call) async {
        if (call.method == 'shared' && call.arguments is Map) _takeShare(Map<String, dynamic>.from(call.arguments as Map));
      });
      final initial = await Device.initialShare();
      if (initial != null) _takeShare(initial);
      final link = await Device.initialLink();
      if (link == 'new' && widget.session.signedIn) widget.session.create();
    }
    if (Platform.isWindows) {
      Device.windows.setMethodCallHandler((call) async {
        if (call.method == 'trayNew' && widget.session.signedIn) widget.session.create();
      });
    }
  }

  void _takeShare(Map<String, dynamic> raw) {
    if (!widget.session.signedIn) return;
    final text = '${raw['text'] ?? ''}';
    final subject = '${raw['subject'] ?? ''}'.trim();
    final note = widget.session.create(title: subject.isEmpty ? '分享进来的' : subject, body: text);
    final files = raw['files'];
    if (files is List) {
      for (final item in files) {
        if (item is Map && item['path'] is String) {
          final path = item['path'] as String;
          final name = '${item['name'] ?? 'file'}';
          final file = File(path);
          file.length().then((len) => widget.session.attach(note, name, file.openRead, len));
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
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
          final home = !session.signedIn
              ? LoginPage(initialServer: session.server ?? '')
              : session.locked
                  ? const LockPage()
                  : const HomePage();
          return MaterialApp(
            title: 'SyncNotes',
            theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF3D5AFE)), useMaterial3: true),
            darkTheme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF3D5AFE), brightness: Brightness.dark), useMaterial3: true),
            themeMode: mode,
            home: home,
          );
        },
      ),
    );
  }
}