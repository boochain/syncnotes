import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:syncnotes/blocks/builtin_types.dart';
import 'package:syncnotes/main.dart';
import 'package:syncnotes/services/settings.dart';
import 'package:syncnotes/sync/local_store.dart';

import 'fake_channel.dart';

void main() {
  setUpAll(registerBuiltinTypes);

  test('forgetting a remembered address stays forgotten, including the current one', () async {
    SharedPreferences.setMockInitialValues({
      'server': 'https://notes.example.com',
      'known_servers': ['https://notes.example.com', 'http://10.0.0.2:8787'],
    });
    final s = await Settings.load();
    expect(s.knownServers, ['https://notes.example.com', 'http://10.0.0.2:8787']);

    s.forgetServer('https://notes.example.com');
    expect(s.knownServers, ['http://10.0.0.2:8787']);
    expect(s.server, 'https://notes.example.com');

    final again = await Settings.load();
    expect(again.knownServers, ['http://10.0.0.2:8787']);

    again.forgetServer('10.0.0.2:8787');
    expect(again.knownServers, isEmpty);

    again.rememberServer('notes.example.com');
    expect(again.knownServers, ['https://notes.example.com']);
  });

  test('current address can be removed when it was only implied, not stored', () async {
    SharedPreferences.setMockInitialValues({'server': 'https://notes.example.com'});
    final s = await Settings.load();
    expect(s.knownServers, ['https://notes.example.com']);
    s.forgetServer('https://notes.example.com');
    expect(s.knownServers, isEmpty);
    expect((await Settings.load()).knownServers, isEmpty);
  });

  testWidgets('login page delete removes the remembered address chip', (tester) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({
      'device_id': 'dev-w',
      'server': 'https://notes.example.com',
      'known_servers': ['https://notes.example.com', 'http://10.0.0.2:8787'],
    });
    final settings = await Settings.load();
    await tester.pumpWidget(SyncNotesApp(
      settings: settings,
      store: MemoryStore(),
      channelFactory: (_) => FakeChannel(),
    ));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('knownServer:https://notes.example.com')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('forgetServer:https://notes.example.com')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('knownServer:https://notes.example.com')), findsNothing);
    expect(find.byKey(const ValueKey('knownServer:http://10.0.0.2:8787')), findsOneWidget);
    expect(settings.knownServers, ['http://10.0.0.2:8787']);
    expect(find.byKey(const Key('serverField')), findsOneWidget);
    expect(tester.widget<TextField>(find.byKey(const Key('serverField'))).controller?.text, isEmpty);
  });

  testWidgets('settings page can delete the current server chip', (tester) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({
      'server': 'https://notes.example.com',
      'token': 'tok',
      'username': 'bill',
      'device_id': 'dev-w',
      'known_servers': ['https://notes.example.com'],
    });
    final settings = await Settings.load();
    final chans = <FakeChannel>[];
    await tester.pumpWidget(SyncNotesApp(
      settings: settings,
      store: MemoryStore(),
      channelFactory: (_) {
        final f = FakeChannel();
        chans.add(f);
        return f;
      },
    ));
    await tester.pumpAndSettle();
    chans.first.serverSend({'type': 'auth_ok', 'user_id': 'u', 'username': 'bill'});
    await tester.pump(const Duration(milliseconds: 50));
    chans.first.serverSend({'type': 'sync_complete', 'latest_seq': 0});
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('homeSettings')));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('forgetServer:https://notes.example.com')),
      200,
      scrollable: find.descendant(of: find.byKey(const Key('settingsList')), matching: find.byType(Scrollable)),
    );
    await tester.tap(find.byKey(const ValueKey('forgetServer:https://notes.example.com')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('knownServer:https://notes.example.com')), findsNothing);
    expect(settings.knownServers, isEmpty);
    expect(settings.server, 'https://notes.example.com');
    expect(settings.token, 'tok');
  });
}
