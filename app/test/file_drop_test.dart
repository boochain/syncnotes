import 'dart:async';
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
import 'package:syncnotes/platform/share_receive.dart';
import 'dart:io';

import 'fake_channel.dart';

class _FakeApi extends AuthApi {
  final uploads = <String>[];
  @override
  Future<UploadedFile> putFile({
    required String server,
    required String token,
    required String name,
    List<int>? bytes,
    Stream<List<int>>? source,
    int total = 0,
    void Function(int done, int total)? onProgress,
    bool Function()? isCanceled,
  }) async {
    uploads.add(name);
    var n = bytes?.length ?? 0;
    if (source != null) {
      await for (final c in source) {
        n += c.length;
      }
    }
    onProgress?.call(n, total == 0 ? n : total);
    return UploadedFile(id: 'fid-$name', sha256: '', size: n);
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
    expect(chans, isNotEmpty);
    expect(find.text('报告.pdf'), findsWidgets); // 收件箱里出现文件块（离线时排队待同步）
    expect(find.text('b.txt'), findsWidgets);
  });

  test('SharedPayload parses the platform map', () {
    expect(SharedPayload.fromMap(null), isNull);
    expect(SharedPayload.fromMap({'text': '  ', 'files': []}), isNull);
    final p = SharedPayload.fromMap({'text': 'hi', 'subject': 's', 'files': [{'name': 'a.png', 'path': '/x/a.png'}]})!;
    expect(p.text, 'hi');
    expect(p.files.single.name, 'a.png');
  });

  testWidgets('shared text becomes a message; shared file is uploaded', (tester) async {
    tester.view.physicalSize = const Size(400, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({'server': 'h:1', 'token': 'tok', 'username': 'bill', 'device_id': 'dev-s'});
    final settings = await Settings.load();
    final api = _FakeApi();
    await tester.pumpWidget(SyncNotesApp(settings: settings, store: MemoryStore(), api: api, channelFactory: (_) => FakeChannel()));
    await tester.pumpAndSettle();
    ShareReceiver.incoming.value = const SharedPayload(text: '分享来的一段文字 https://example.com', subject: '标题');
    await tester.pumpAndSettle();
    expect(find.textContaining('分享来的一段文字'), findsWidgets);
    expect(find.text('已保存分享的内容'), findsOneWidget);

    late File f;
    await tester.runAsync(() async {
      f = File('${Directory.systemTemp.path}/share_test_${DateTime.now().microsecondsSinceEpoch}.txt');
      await f.writeAsString('hello');
    });
    ShareReceiver.incoming.value = SharedPayload(files: [(name: '分享.txt', path: f.path)]);
    for (var i = 0; i < 10 && api.uploads.isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(api.uploads, ['分享.txt']);
    expect(find.text('分享.txt'), findsWidgets);
  });
}
