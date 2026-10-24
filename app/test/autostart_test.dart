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
}
