import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'app_scope.dart';
import 'blocks/builtin_types.dart';
import 'models/block.dart';
import 'platform/android_service.dart';
import 'platform/desktop.dart';
import 'platform/notifications.dart';
import 'services/auth_api.dart';
import 'services/settings.dart';
import 'sync/local_store.dart';
import 'sync/sync_client.dart';
import 'ui/home_page.dart';
import 'ui/login_page.dart';

Future<void> main(List<String> args) async {
  // 插件的异步错误（如缺少 D-Bus）不应导致应用崩溃
  runZonedGuarded(() => _main(args), (e, st) => debugPrint('Unhandled: $e\n$st'));
}

Future<void> _main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  registerBuiltinTypes();
  final settings = await Settings.load();

  if (isDesktop) {
    final hidden = args.contains('--hidden') || (settings.isLoggedIn && settings.startMinimized);
    await DesktopShell.instance.init(startHidden: hidden);
  }
  if (Platform.isAndroid) {
    AndroidSyncService.init(autoRunOnBoot: settings.autoStart);
  }
  unawaited(Notifier.init());

  final dir = await getApplicationSupportDirectory();
  runApp(SyncNotesApp(
    settings: settings,
    store: FileStore(File('${dir.path}${Platform.pathSeparator}syncnotes_cache.json')),
  ));
}

ThemeData buildTheme(Brightness b) => ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF3F6FD8), brightness: b),
      pageTransitionsTheme: const PageTransitionsTheme(builders: {
        TargetPlatform.android: PredictiveBackPageTransitionsBuilder(),
        TargetPlatform.linux: FadeForwardsPageTransitionsBuilder(),
        TargetPlatform.windows: FadeForwardsPageTransitionsBuilder(),
      }),
    );

class SyncNotesApp extends StatefulWidget {
  final Settings settings;
  final LocalStore store;
  final AuthApi? api;
  final ChannelFactory? channelFactory;
  const SyncNotesApp(
      {super.key, required this.settings, required this.store, this.api, this.channelFactory});

  @override
  State<SyncNotesApp> createState() => _SyncNotesAppState();
}

class _SyncNotesAppState extends State<SyncNotesApp> with WidgetsBindingObserver {
  late final AuthApi _api = widget.api ?? AuthApi();
  late SyncClient _sync;
  late AppServices _services;
  bool _loggedIn = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _sync = _newClient();
    _services = _makeServices();
    _loggedIn = widget.settings.isLoggedIn;
    _sync.loadLocal().then((_) {
      if (_loggedIn) _start(); // 自动登录：使用保存的令牌
    });
  }

  SyncClient _newClient() {
    final c = SyncClient(
      store: widget.store,
      deviceId: widget.settings.deviceId,
      channelFactory: widget.channelFactory,
    );
    c.onRemoteNew = _onRemoteNew;
    c.addListener(_onSyncChanged);
    return c;
  }

  AppServices _makeServices() =>
      AppServices(sync: _sync, settings: widget.settings, api: _api, logout: _logout);

  void _onRemoteNew(Block b) {
    if (!widget.settings.notifications) return;
    // Android 开启前台服务时由服务负责通知，避免重复
    if (Platform.isAndroid && widget.settings.foregroundService) return;
    if (b.kind == BlockKind.folder) return;
    Notifier.showBlock(b);
  }

  int _lastUnread = -1;
  ConnState _lastState = ConnState.offline;
  void _onSyncChanged() {
    if (isDesktop && _sync.unreadCount != _lastUnread) {
      _lastUnread = _sync.unreadCount;
      DesktopShell.instance.updateUnread(_lastUnread);
    }
    if (_sync.state == ConnState.authError && _lastState != ConnState.authError) {
      // 令牌失效 → 回到登录页
      widget.settings.logout();
      if (mounted) setState(() => _loggedIn = false);
    }
    _lastState = _sync.state;
  }

  void _start() {
    _sync.connect(widget.settings.server!, widget.settings.token!);
    if (Platform.isAndroid && widget.settings.foregroundService) {
      AndroidSyncService.start();
    }
  }

  Future<void> _logout() async {
    _sync.disconnect();
    await _sync.clearLocal();
    widget.settings.logout();
    if (Platform.isAndroid) await AndroidSyncService.stop();
    setState(() => _loggedIn = false);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _sync.reconnectNow();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _sync.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AppScope(
      services: _services,
      child: MaterialApp(
        title: 'SyncNotes',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(Brightness.light),
        darkTheme: buildTheme(Brightness.dark),
        locale: const Locale('zh', 'CN'),
        home: AnimatedSwitcher(
          duration: const Duration(milliseconds: 350),
          switchInCurve: Curves.easeOutCubic,
          child: _loggedIn
              ? const HomePage(key: ValueKey('home'))
              : LoginPage(
                  key: const ValueKey('login'),
                  settings: widget.settings,
                  api: _api,
                  onLoggedIn: () {
                    setState(() => _loggedIn = true);
                    _start();
                  },
                ),
        ),
      ),
    );
  }
}
