import 'dart:async';
import 'dart:io';
import 'ui/motion.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:path_provider/path_provider.dart';

import 'app_scope.dart';
import 'blocks/builtin_types.dart';
import 'models/block.dart';
import 'platform/android_service.dart';
import 'platform/desktop.dart';
import 'platform/notifications.dart';
import 'platform/single_instance.dart';
import 'services/auth_api.dart';
import 'services/settings.dart';
import 'sync/local_store.dart';
import 'sync/sync_client.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import 'ui/app_shell.dart';
import 'ui/back_handler.dart';
import 'ui/glass.dart';
import 'ui/theme.dart';
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
    final primary = await SingleInstance.acquire(onActivate: () => DesktopShell.instance.showNearTray());
    if (!primary) exit(0);
    final hidden = args.contains('--hidden') || (settings.isLoggedIn && settings.startMinimized);
    try {
      await DesktopShell.instance.init(startHidden: hidden, settings: settings);
    } catch (e, st) {
      debugPrint('desktop init failed: $e\n$st');
    }
  }
  if (Platform.isAndroid) {
    AndroidSyncService.init(autoRunOnBoot: settings.autoStart);
    // 全面屏（edge-to-edge）：状态栏 / 导航栏透明，内容用 SafeArea 避让
    unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
  }
  unawaited(Notifier.init());
  Glass.useShader = Platform.environment['SYNCNOTES_GLASS'] != '0';
  Glass.enabled.value = settings.liquidGlass;
  Glass.opacity.value = settings.glassOpacity;
  Glass.preset.value = settings.bgPreset;
  if (Glass.useShader) {
    try {
      await LiquidGlassWidgets.initialize(enablePerformanceMonitor: false);
    } catch (e, st) {
      debugPrint('glass init failed: $e\n$st');
      Glass.useShader = false;
    }
  }

  final dir = await getApplicationSupportDirectory();
  settings.localDataDir = dir.path;
  final app = SyncNotesApp(
    settings: settings,
    store: FileStore(File('${dir.path}${Platform.pathSeparator}syncnotes_cache.json')),
  );
  runApp(Glass.useShader
      ? LiquidGlassWidgets.wrap(
          brightnessResolver: Theme.maybeBrightnessOf,
          adaptiveQuality: false,
          child: app,
        )
      : app);
}

ThemeData buildTheme(Brightness b) => buildAppTheme(b, preset: Glass.preset.value);

/// 透明状态栏 / 导航栏；浅色主题用深色图标，深色主题用浅色图标。
SystemUiOverlayStyle systemBarsStyle(Brightness b) {
  final dark = b == Brightness.dark;
  return SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    systemNavigationBarColor: Colors.transparent,
    systemNavigationBarDividerColor: Colors.transparent,
    systemNavigationBarContrastEnforced: false,
    statusBarIconBrightness: dark ? Brightness.light : Brightness.dark,
    statusBarBrightness: b,
    systemNavigationBarIconBrightness: dark ? Brightness.light : Brightness.dark,
  );
}

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
  late final AuthApi _api = widget.api ?? AuthApi(pins: widget.settings);
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
      settings: widget.settings,
      channelFactory: widget.channelFactory,
    );
    c.onRemoteNew = _onRemoteNew;
    if (isDesktop) DesktopShell.instance.onQuit = c.flush;
    c.addListener(_onSyncChanged);
    return c;
  }

  AppServices _makeServices() =>
      AppServices(sync: _sync, settings: widget.settings, api: _api, logout: _logout, themeMode: _themeMode);
  late final _themeMode = ValueNotifier(AppServices.parseTheme(widget.settings.themeMode));

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
    final server = widget.settings.server, token = widget.settings.token;
    if (server != null && token != null) _api.logout(server, token);
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
      child: ValueListenableBuilder<String>(
        valueListenable: Glass.preset,
        builder: (context, preset, _) => ValueListenableBuilder<ThemeMode>(
        valueListenable: _themeMode,
        builder: (context, mode, _) => MaterialApp(
        themeMode: mode,
        title: 'SyncNotes',
        debugShowCheckedModeBanner: false,
        theme: buildAppTheme(Brightness.light, preset: preset),
        darkTheme: buildAppTheme(Brightness.dark, preset: preset),
        locale: const Locale('zh', 'CN'),
        supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        // 系统栏图标随主题明暗切换（没有 AppBar 的页面也正确）
        builder: (context, child) {
          return ValueListenableBuilder<bool>(
            valueListenable: Glass.enabled,
            builder: (context, on, child) {
              final theme = Theme.of(context);
              Widget page = child!;
              if (on) page = Theme(data: glassTheme(theme, true), child: page);
              return AnnotatedRegion<SystemUiOverlayStyle>(
                value: systemBarsStyle(theme.brightness),
                child: page,
              );
            },
            child: child,
          );
        },
        home: MotionSwitch(
          child: _loggedIn
              ? const AppShell(key: ValueKey('home'))
              : RootBackScope(key: const ValueKey('login'), child: GlassBackdrop(child: LoginPage(
                  key: const ValueKey('login'),
                  settings: widget.settings,
                  api: _api,
                  onLoggedIn: () {
                    setState(() => _loggedIn = true);
                    _start();
                  },
                ))),
        ),
      ),
      ),
      ),
    );
  }
}
