import 'dart:ui' show Rect;

import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

/// 持久化设置（登录信息用于自动登录）。
class Settings {
  final SharedPreferences prefs;
  Settings(this.prefs);

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
  set server(String? v) => v == null ? prefs.remove('server') : prefs.setString('server', v);

  String? get token => prefs.getString('token');
  set token(String? v) => v == null ? prefs.remove('token') : prefs.setString('token', v);

  String? get username => prefs.getString('username');
  set username(String? v) => v == null ? prefs.remove('username') : prefs.setString('username', v);

  bool get autoStart => prefs.getBool('auto_start') ?? false;
  set autoStart(bool v) => prefs.setBool('auto_start', v);

  bool get notifications => prefs.getBool('notifications') ?? true;
  set notifications(bool v) => prefs.setBool('notifications', v);

  /// 是否已经向用户说明过通知权限（只主动问一次）
  bool get notificationRationaleShown => prefs.getBool('notif_rationale_shown') ?? false;
  set notificationRationaleShown(bool v) => prefs.setBool('notif_rationale_shown', v);

  bool get startMinimized => prefs.getBool('start_minimized') ?? true;
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

  void setSealPin(String server, String hex) => prefs.setString(_pinKey(server), hex);

  void clearSealPin(String server) => prefs.remove(_pinKey(server));

  void clearSealPins() {
    for (final k in prefs.getKeys().where((k) => k.startsWith('seal_pin_')).toList()) {
      prefs.remove(k);
    }
  }
}
