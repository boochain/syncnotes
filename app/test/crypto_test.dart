import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syncnotes/api.dart';
import 'package:syncnotes/crypto.dart';
import 'package:syncnotes/desktop.dart';
import 'package:syncnotes/login_page.dart';
import 'package:syncnotes/scope.dart';
import 'package:syncnotes/session.dart';
import 'package:syncnotes/settings_store.dart';

void main() {
  test('password seals a note and a file, including more than one chunk', () async {
    final box = await NoteCipher.fromPassword('secret1', memoryKiB: 32, iterations: 1);
    final sealed = await box.sealText('你好');
    final other = NoteCipher.fromBytes(await box.extract());
    expect(await other.openText(sealed.nonce, sealed.ciphertext), '你好');

    final plain = Uint8List.fromList(List<int>.generate(50, (i) => i));
    final bytes = await box.sealBytes(plain, chunk: 16);
    expect(bytes.sublist(0, 4), NoteCipher.magic);
    expect(await box.openBytes(bytes), plain);
    expect(await box.openBytes(await box.sealBytes(Uint8List(0))), isEmpty);
  });

  test('domains default to https and local addresses stay on http', () {
    expect(normalizeServer('notes.example.com'), 'https://notes.example.com');
    expect(normalizeServer('127.0.0.1:7700'), 'http://127.0.0.1:7700');
    expect(normalizeServer('http://10.0.0.8:7700/'), 'http://10.0.0.8:7700');
  });

  test('expand and collapse never keep the same window size', () {
    const wide = Size(1100, 720);
    expect(Desk.sizeForToggle(expand: false, current: wide, saved: wide), Desk.compact);
    expect(Desk.sizeForToggle(expand: true, current: Desk.compact, saved: Desk.compact), Desk.expandedSize);
    expect(Desk.sizeForToggle(expand: false, current: wide, saved: const Size(420, 640)).width, 420);
  });

  testWidgets('login page offers sign in and register', (tester) async {
    final session = Session(
      prefs: SettingsStore.memory({'server': 'http://127.0.0.1:7700'}),
      api: SyncApi(),
      supportDir: Directory.systemTemp,
    );
    await tester.pumpWidget(MaterialApp(home: Scope(session: session, child: const LoginPage(initialServer: 'http://127.0.0.1:7700'))));
    expect(find.text('登录'), findsOneWidget);
    expect(find.text('注册'), findsOneWidget);
    expect(find.text('http://127.0.0.1:7700'), findsOneWidget);
  });
}
