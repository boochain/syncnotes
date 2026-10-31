import 'package:shared_preferences/shared_preferences.dart';

class SettingsStore {
  SettingsStore._(this._prefs, Map<String, Object?>? mem) : _mem = mem;
  final SharedPreferences? _prefs;
  final Map<String, Object?>? _mem;

  factory SettingsStore.memory([Map<String, Object?> seed = const {}]) => SettingsStore._(null, Map<String, Object?>.of(seed));

  static Future<SettingsStore> load() async => SettingsStore._(await SharedPreferences.getInstance(), null);

  String? getString(String k) => _mem != null ? _mem[k] as String? : _prefs!.getString(k);
  bool? getBool(String k) => _mem != null ? _mem[k] as bool? : _prefs!.getBool(k);

  Future<void> setString(String k, String v) async {
    if (_mem != null) {
      _mem[k] = v;
    } else {
      await _prefs!.setString(k, v);
    }
  }

  Future<void> setBool(String k, bool v) async {
    if (_mem != null) {
      _mem[k] = v;
    } else {
      await _prefs!.setBool(k, v);
    }
  }

  List<String> getStringList(String k) {
    if (_mem != null) {
      final v = _mem[k];
      if (v is List) return [for (final e in v) '$e'];
      return const [];
    }
    return _prefs!.getStringList(k) ?? const [];
  }

  Future<void> setStringList(String k, List<String> v) async {
    if (_mem != null) {
      _mem[k] = v;
    } else {
      await _prefs!.setStringList(k, v);
    }
  }

  Future<void> remove(String k) async {
    if (_mem != null) {
      _mem.remove(k);
    } else {
      await _prefs!.remove(k);
    }
  }
}
