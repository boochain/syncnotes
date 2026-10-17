import 'dart:typed_data';
import 'package:cross_file/cross_file.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:syncnotes/blocks/builtin_types.dart';
import 'package:syncnotes/main.dart';
import 'package:syncnotes/services/auth_api.dart';
import 'package:syncnotes/services/settings.dart';
import 'package:syncnotes/sync/local_store.dart';
import 'package:syncnotes/ui/file_drop.dart';

import 'fake_channel.dart';

class _FakeApi extends AuthApi {
  final uploads = <String>[];
  @override
  Future<String> uploadFile(String server, String token, String name, List<int> bytes) async {
    uploads.add(name);
    return 'fid-$name';
  }
}

void main() {
  setUpAll(registerBuiltinTypes);

  testWidgets('dropping files onto the window creates file blocks', (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({'server': 'h:1', 'token': 'tok', 'username': 'bill', 'device_id': 'dev-d'});
    final settings = await Settings.load();
    final api = _FakeApi();
    final chans = <FakeChannel>[];
    await tester.pumpWidget(SyncNotesApp(
      settings: settings,
      store: MemoryStore(),
      api: api,
      channelFactory: (_) {
        final f = FakeChannel();
        chans.add(f);
        return f;
      },
    ));
    await tester.pumpAndSettle();
    final st = tester.state<FileDropZoneState>(find.byType(FileDropZone));
    late int n;
    await tester.runAsync(() async {
      n = await st.handleFiles([
        XFile.fromData(Uint8List.fromList([1, 2, 3]), name: '报告.pdf', path: '/tmp/报告.pdf'),
        XFile.fromData(Uint8List.fromList([4, 5]), name: 'b.txt', path: '/tmp/b.txt'),
      ]);
    });
    await tester.pumpAndSettle();
    expect(n, 2);
    expect(api.uploads, ['报告.pdf', 'b.txt']);
    final ups = chans.first.sentOfType('upsert_block').where((u) => u['kind'] == 'file').toList();
    expect(ups.map((u) => u['title']), ['报告.pdf', 'b.txt']);
    expect(ups.first['payload']['size'], 3);
  });
}
