import 'dart:io';

/// 开机/登录自启（无第三方依赖）：
/// - Linux：写入 ~/.config/autostart/syncnotes.desktop（XDG 标准）
/// - Windows：HKCU\Software\Microsoft\Windows\CurrentVersion\Run
class AutoStart {
  static const appName = 'SyncNotes';
  static const _runKey = r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run';

  /// 可注入以便测试
  static String? homeOverride;
  static String exePath = Platform.resolvedExecutable;

  static File _linuxDesktopFile() {
    final home = homeOverride ?? Platform.environment['HOME'] ?? '.';
    final cfg = Platform.environment['XDG_CONFIG_HOME'];
    final base = (homeOverride == null && cfg != null && cfg.isNotEmpty) ? cfg : '$home/.config';
    return File('$base/autostart/syncnotes.desktop');
  }

  static String linuxDesktopEntry(String exe) => '''[Desktop Entry]
Type=Application
Name=SyncNotes
Comment=多设备实时同步笔记
Exec="$exe" --hidden
Terminal=false
X-GNOME-Autostart-enabled=true
''';

  static Future<bool> isEnabled() async {
    if (Platform.isLinux) return _linuxDesktopFile().exists();
    if (Platform.isWindows) {
      final r = await Process.run('reg', ['query', _runKey, '/v', appName]);
      return r.exitCode == 0;
    }
    return false;
  }

  static Future<void> setEnabled(bool on) async {
    if (Platform.isLinux) {
      final f = _linuxDesktopFile();
      if (on) {
        await f.parent.create(recursive: true);
        await f.writeAsString(linuxDesktopEntry(exePath));
      } else if (await f.exists()) {
        await f.delete();
      }
    } else if (Platform.isWindows) {
      final args = on
          ? ['add', _runKey, '/v', appName, '/t', 'REG_SZ', '/d', '"$exePath" --hidden', '/f']
          : ['delete', _runKey, '/v', appName, '/f'];
      await Process.run('reg', args);
    }
  }
}
