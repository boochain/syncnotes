import 'dart:ui' show Rect;

import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

/// 持久化设置（登录信息用于自动登录）。
class Settings {
  final SharedPreferences prefs;
  Settings(this.prefs);

  /// 本机数据目录。不写入配置。和程序目录分开，覆盖安装不会清掉。
  String? localDataDir;

  static Future<Settings> load() async => Settings(await SharedPreferences.getInstance());

  String get deviceId {
    var id = prefs.getString('device_id');
    if (id == null) {
      id = const Uuid().v4();
      prefs.setString('device_id', id);
    }
    return id;
  }

  String? get server => prefs.getString('server');
  set server(String? v) => v == null ? prefs.remove('server') : prefs.setString('server', normalizeServer(v));

  /// 登录过的地址，最多 8 个。当前地址始终算在里面。
  List<String> get knownServers {
    final list = prefs.getStringList('known_servers') ?? const <String>[];
    final cur = prefs.getString('server');
    if (cur != null && cur.isNotEmpty && !list.contains(cur)) return [cur, ...list];
    return list;
  }

  void rememberServer(String raw) {
    final s = normalizeServer(raw);
    if (s.isEmpty) return;
    final next = [s, ...knownServers.where((e) => e != s)].take(8).toList();
    prefs.setStringList('known_servers', next);
  }

  void forgetServer(String raw) {
    final s = normalizeServer(raw);
    prefs.setStringList('known_servers', knownServers.where((e) => e != s).toList());
  }

  /// default / sea / dusk / paper / ink
  String get bgPreset => prefs.getString('bg_preset') ?? 'default';
  set bgPreset(String v) => prefs.setString('bg_preset', v);

  /// 浮层玻璃的不透明度。越小越透。
  double get glassOpacity {
    final v = prefs.getDouble('glass_opacity');
    if (v == null) return 0.55;
    if (v < 0.35) return 0.35;
    if (v > 0.92) return 0.92;
    return v;
  }

  set glassOpacity(double v) => prefs.setDouble('glass_opacity', v < 0.35 ? 0.35 : (v > 0.92 ? 0.92 : v));

  String? get token => prefs.getString('token');
  set token(String? v) => v == null ? prefs.remove('token') : prefs.setString('token', v);

  String? get username => prefs.getString('username');
  set username(String? v) => v == null ? prefs.remove('username') : prefs.setString('username', v);

  bool get rememberPassword => prefs.getBool('remember_password') ?? false;
  set rememberPassword(bool v) => prefs.setBool('remember_password', v);

  /// 仅在用户勾选「记住密码」时保存。和令牌一样放在本机设置里。
  String? get savedPassword => prefs.getString('saved_password');
  set savedPassword(String? v) => v == null || v.isEmpty ? prefs.remove('saved_password') : prefs.setString('saved_password', v);

  /// 液态玻璃。默认开。
  bool get liquidGlass => prefs.getBool('liquid_glass') ?? true;
  set liquidGlass(bool v) => prefs.setBool('liquid_glass', v);

  bool get autoStart => prefs.getBool('auto_start') ?? false;
  set autoStart(bool v) => prefs.setBool('auto_start', v);

  bool get notifications => prefs.getBool('notifications') ?? true;
  set notifications(bool v) => prefs.setBool('notifications', v);

  /// 是否已经向用户说明过通知权限（只主动问一次）
  bool get notificationRationaleShown => prefs.getBool('notif_rationale_shown') ?? false;
  set notificationRationaleShown(bool v) => prefs.setBool('notif_rationale_shown', v);

  /// 桌面启动时藏进托盘。默认关：登录后双击程序必须能看到窗口。
  bool get startMinimized => prefs.getBool('start_minimized') ?? false;
  set startMinimized(bool v) => prefs.setBool('start_minimized', v);

  /// 新建块时默认的已读模式
  bool get defaultGlobalViewed => prefs.getBool('default_global_viewed') ?? false;
  set defaultGlobalViewed(bool v) => prefs.setBool('default_global_viewed', v);

  bool get foregroundService => prefs.getBool('foreground_service') ?? true;
  set foregroundService(bool v) => prefs.setBool('foreground_service', v);

  /// system / light / dark
  String get themeMode => prefs.getString('theme_mode') ?? 'system';
  set themeMode(String v) => prefs.setString('theme_mode', v);

  /// 桌面：点关闭按钮时隐藏到托盘（true）还是直接退出（false）
  bool get closeToTray => prefs.getBool('close_to_tray') ?? true;
  set closeToTray(bool v) => prefs.setBool('close_to_tray', v);

  /// 桌面窗口用侧边栏布局。默认开；收起后记住，避免每次启动都变回 400px 的手机窗口。
  bool get windowExpanded => prefs.getBool('window_expanded') ?? true;
  set windowExpanded(bool v) => prefs.setBool('window_expanded', v);

  /// 桌面：记住窗口位置和大小（[mode] = compact / expanded）
  Rect? windowBounds(String mode) {
    final v = prefs.getStringList('window_$mode');
    if (v == null || v.length != 4) return null;
    final n = v.map(double.tryParse).toList();
    if (n.any((e) => e == null)) return null;
    return Rect.fromLTWH(n[0]!, n[1]!, n[2]!, n[3]!);
  }

  void setWindowBounds(String mode, Rect r) =>
      prefs.setStringList('window_$mode', [r.left, r.top, r.width, r.height].map((e) => e.toStringAsFixed(0)).toList());

  bool get isLoggedIn => token != null && server != null;

  void logout() {
    token = null;
  }

  String _pinKey(String server) => 'seal_pin_${server.trim()}';

  /// 第一次连上时记住的服务器公钥指纹（十六进制）。
  String? sealPin(String server) => prefs.getString(_pinKey(server));

  Future<bool> setSealPin(String server, String hex) => prefs.setString(_pinKey(server), hex);

  void clearSealPin(String server) => prefs.remove(_pinKey(server));

  void clearSealPins() {
    for (final k in prefs.getKeys().where((k) => k.startsWith('seal_pin_')).toList()) {
      prefs.remove(k);
    }
  }
}

/// 没写协议时：域名用 https，IP / localhost / .local 用 http（这些通常没有证书）。
String normalizeServer(String raw) {
  var s = raw.trim();
  if (s.isEmpty) return s;
  while (s.endsWith('/')) {
    s = s.substring(0, s.length - 1);
  }
  if (s.startsWith('ws://')) s = 'http://${s.substring(5)}';
  if (s.startsWith('wss://')) s = 'https://${s.substring(6)}';
  if (s.contains('://')) return s;
  final hostport = s.split('/').first;
  final host = hostport.startsWith('[') ? hostport : hostport.split(':').first;
  final local = host == 'localhost' ||
      host.endsWith('.local') ||
      host.endsWith('.lan') ||
      RegExp(r'^\d{1,3}(\.\d{1,3}){3}$').hasMatch(host) ||
      host.startsWith('[');
  return '${local ? 'http' : 'https'}://$s';
}
