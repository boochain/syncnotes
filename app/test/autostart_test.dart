import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:syncnotes/platform/autostart.dart';

void main() {
  test('linux autostart writes and removes XDG desktop entry', () async {
    if (!Platform.isLinux) return;
    final tmp = await Directory.systemTemp.createTemp('sn-auto');
    AutoStart.homeOverride = tmp.path;
    AutoStart.exePath = '/opt/syncnotes/syncnotes';
    expect(await AutoStart.isEnabled(), isFalse);
    await AutoStart.setEnabled(true);
    expect(await AutoStart.isEnabled(), isTrue);
    final f = File('${tmp.path}/.config/autostart/syncnotes.desktop');
    expect(await f.readAsString(), contains('Exec="/opt/syncnotes/syncnotes"\n'));
    expect(await f.readAsString(), isNot(contains('--hidden')));
    await AutoStart.setEnabled(false);
    expect(await AutoStart.isEnabled(), isFalse);
    await tmp.delete(recursive: true);
  });

  test('windows autostart quotes a path only when it contains spaces', () {
    expect(AutoStart.windowsRunCommand(r'C:\SyncNotes\syncnotes.exe'), r'C:\SyncNotes\syncnotes.exe');
    expect(
      AutoStart.windowsRunCommand(r'C:\Program Files\SyncNotes\syncnotes.exe'),
      r'"C:\Program Files\SyncNotes\syncnotes.exe"',
    );
    const broken = r'''
HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Run
    SyncNotes    REG_SZ    "C:\SyncNotes\syncnotes.exe"
''';
    expect(AutoStart.windowsRunValueOk(broken, r'C:\SyncNotes\syncnotes.exe'), isFalse);
    const ok = r'''
    SyncNotes    REG_SZ    C:\SyncNotes\syncnotes.exe
''';
    expect(AutoStart.windowsRunValueOk(ok, r'C:\SyncNotes\syncnotes.exe'), isTrue);
  });
}
