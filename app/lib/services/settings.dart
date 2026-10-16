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

  bool get isLoggedIn => token != null && server != null;

  void logout() {
    token = null;
  }
}
