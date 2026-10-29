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
Exec="$exe"
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

  /// 路径里没有空格时不要加引号。`reg add` 经 [Process.run] 不会再剥引号，
  /// 写进注册表的 `"C:\syncnotes.exe"` 会被当成带引号的文件名，开机启动就失败，
  /// 但查询仍然成功，开关看起来是开的。
  static String windowsRunCommand(String exe) => exe.contains(' ') ? '"$exe"' : exe;

  /// `reg query` 的文本里，REG_SZ 后面是否正好是 [windowsRunCommand]。
  static bool windowsRunValueOk(String queryOutput, String exe) {
    final want = windowsRunCommand(exe);
    for (final line in queryOutput.split('\n')) {
      final i = line.indexOf('REG_SZ');
      if (i < 0) continue;
      return line.substring(i + 'REG_SZ'.length).trim() == want;
    }
    return false;
  }

  /// 已经开了自启、但注册表里的命令是旧版本写坏的，就改成当前程序。
  static Future<void> repairIfNeeded() async {
    if (!Platform.isWindows) return;
    try {
      final r = await Process.run('reg', ['query', _runKey, '/v', appName]);
      if (r.exitCode != 0) return;
      if (windowsRunValueOk('${r.stdout}', exePath)) return;
      await setEnabled(true);
    } catch (_) {}
  }

  /// 登录时启动程序本身。要不要藏进托盘由设置「启动时最小化」决定，
  /// 这里不要再加 --hidden，否则那个开关对自启无效，没有托盘图标时程序会直接消失。
  static Future<bool> setEnabled(bool on) async {
    try {
      if (Platform.isLinux) {
        final f = _linuxDesktopFile();
        if (on) {
          await f.parent.create(recursive: true);
          await f.writeAsString(linuxDesktopEntry(exePath));
        } else if (await f.exists()) {
          await f.delete();
        }
        return true;
      }
      if (Platform.isWindows) {
        final args = on
            ? ['add', _runKey, '/v', appName, '/t', 'REG_SZ', '/d', windowsRunCommand(exePath), '/f']
            : ['delete', _runKey, '/v', appName, '/f'];
        final r = await Process.run('reg', args);
        return r.exitCode == 0;
      }
    } catch (_) {}
    return false;
  }
}
