import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syncnotes/models/block.dart';
import 'package:syncnotes/services/data_export.dart';
import 'package:syncnotes/sync/local_store.dart';
import 'package:syncnotes/sync/sync_client.dart';

import 'fake_channel.dart';

Map<String, dynamic> serverBlock(
  String id, {
  String kind = 'note',
  String title = 't',
  Map<String, dynamic>? payload,
  int seq = 1,
  int updated = 1,
  bool deleted = false,
}) => {
  'id': id,
  'kind': kind,
  'title': title,
  'payload': payload ?? {'markdown': 'hi'},
  'parent_id': null,
  'viewed_mode': 'global',
  'viewed_global': false,
  'created_at': updated,
  'updated_at': updated,
  'created_by': 'other',
  'deleted': deleted,
  'seq': seq,
};

List<int> _zip(Map<String, String> files) {
  final a = Archive();
  files.forEach((n, s) {
    final b = utf8.encode(s);
    a.addFile(ArchiveFile(n, b.length, b));
  });
  return ZipEncoder().encodeBytes(a);
}

void main() {
  group('备份格式', () {
    test('inspectBackup 识别 syncnotes-export 并拒绝错误格式', () {
      final ok = _zip({
        'manifest.json': jsonEncode({
          'format': 'syncnotes-export',
          'version': 1,
          'username': 'bill',
          'exported_at': '2026-11-28T00:00:00Z',
          'blocks': 1,
          'files': 0,
        }),
        'blocks.json': jsonEncode([
          {'id': 'n1', 'kind': 'note', 'title': 'A'},
        ]),
        'pending_outbox.json': jsonEncode([
          {'type': 'upsert_block', 'id': 'n2'},
        ]),
      });
      final info = inspectBackup(ok);
      expect(info.supported, isTrue);
      expect(info.username, 'bill');
      expect(info.pending, 1);
      expect(info.blocks, 1);

      final bad = _zip({
        'manifest.json': jsonEncode({'format': 'other', 'version': 1}),
        'blocks.json': '[]',
      });
      expect(() => inspectBackup(bad), throwsFormatException);
      expect(
        () => inspectBackup(_zip({'readme.txt': 'nope'})),
        throwsFormatException,
      );
    });

    test('mergeBackupWithLocal 把未同步修改和本机附件叠到服务器备份上', () {
      final server = _zip({
        'manifest.json': jsonEncode({
          'format': 'syncnotes-export',
          'version': 1,
          'username': 'alice',
          'blocks': 1,
        }),
        'blocks.json': jsonEncode([
          {
            'id': 'n1',
            'kind': 'note',
            'title': '服务器版',
            'payload': {'markdown': 'server'},
            'updated_at': 10,
            'created_at': 10,
            'deleted': false,
          },
        ]),
        'device_views.json': jsonEncode([
          {'block_id': 'n1', 'device_id': 'phone', 'viewed': true},
        ]),
        'files/ffff0000-x.bin': 'OLD',
      });
      final cache = {
        'last_seq': 3,
        'blocks': [
          {
            'id': 'n1',
            'kind': 'note',
            'title': '本地未同步',
            'payload': {'markdown': 'local'},
            'updated_at': 99,
          },
        ],
        'outbox': [
          {
            'type': 'upsert_block',
            'id': 'n1',
            'kind': 'note',
            'title': '未同步的修改',
            'payload': {'markdown': 'offline'},
            'client_updated_at': 99,
            'deleted': false,
          },
          {
            'type': 'upsert_block',
            'id': 'n2',
            'kind': 'note',
            'title': '离线新建',
            'payload': {'markdown': 'new'},
            'client_updated_at': 100,
            'deleted': false,
          },
        ],
      };
      final bytes = mergeBackupWithLocal(
        serverZip: server,
        cache: cache,
        extraFiles: {
          'abcd1234-file': [1, 2, 3],
        },
        username: 'bill',
        server: 'h:1',
        now: DateTime.utc(2026, 11, 28),
      );
      final z = ZipDecoder().decodeBytes(bytes);
      String read(String n) => utf8.decode(z.findFile(n)!.content as List<int>);
      final manifest = jsonDecode(read('manifest.json')) as Map;
      expect(manifest['source'], 'client-backup');
      expect(manifest['version'], 2);
      expect(manifest['pending_changes'], 2);
      expect(manifest['username'], 'bill');
      final blocks = (jsonDecode(read('blocks.json')) as List).cast<Map>();
      expect(blocks.singleWhere((b) => b['id'] == 'n1')['title'], '未同步的修改');
      expect(blocks.singleWhere((b) => b['id'] == 'n1')['updated_at'], 99);
      expect(
        blocks.any((b) => b['id'] == 'n2' && b['title'] == '离线新建'),
        isTrue,
      );
      expect(jsonDecode(read('pending_outbox.json')), isNotEmpty);
      expect(
        utf8.decode(z.findFile('device_views.json')!.content as List<int>),
        contains('phone'),
      );
      expect(
        z.findFile('files/abcd1234-abcd1234-file') ??
            z.files.firstWhere((f) => f.name.startsWith('files/abcd1234')),
        isNotNull,
      );
    });

    test('buildLocalExport 可标记为 client-backup', () async {
      final r = await buildLocalExport(
        cache: {
          'blocks': [
            {
              'id': 'n1',
              'kind': 'note',
              'title': 'A',
              'payload': {'markdown': 'x'},
              'created_at': 1,
              'updated_at': 1,
              'deleted': false,
            },
          ],
          'outbox': [],
        },
        username: 'bill',
        source: 'client-backup',
        formatVersion: 2,
      );
      final z = ZipDecoder().decodeBytes(r.bytes);
      final m =
          jsonDecode(
                utf8.decode(z.findFile('manifest.json')!.content as List<int>),
              )
              as Map;
      expect(m['source'], 'client-backup');
      expect(m['version'], 2);
    });
  });

  group('立即同步', () {
    late List<FakeChannel> channels;
    late SyncClient c;
    late MemoryStore store;

    setUp(() {
      channels = [];
      store = MemoryStore();
      c = SyncClient(
        store: store,
        deviceId: 'dev-a',
        maxBackoff: const Duration(milliseconds: 20),
        channelFactory: (uri) {
          final f = FakeChannel();
          channels.add(f);
          return f;
        },
      );
    });
    tearDown(() => c.dispose());

    Future<void> pump() =>
        Future<void>.delayed(const Duration(milliseconds: 5));
    FakeChannel ch() => channels.last;

    test('只上传 outbox，不把已同步的块再发一遍', () async {
      c.connect('h:1', 'tok');
      await pump();
      ch().serverSend({'type': 'auth_ok', 'user_id': 'u', 'username': 'bill'});
      await pump();
      ch().serverSend({
        'type': 'block_update',
        'block': serverBlock('old', title: '已在服务器', seq: 1, updated: 1),
      });
      ch().serverSend({'type': 'sync_complete', 'latest_seq': 1});
      await pump();
      // 制造一条未同步修改
      c.create(kind: BlockKind.note, title: '未同步', payload: {'markdown': 'x'});
      await pump();
      expect(c.pendingCount, 1);
      ch().sent.clear();

      final future = c.syncNow(timeout: const Duration(seconds: 2));
      await pump();
      // 会再拉一次 catch-up
      expect(ch().sentOfType('sync_since'), isNotEmpty);
      ch().serverSend({'type': 'sync_complete', 'latest_seq': 1});
      await pump();
      final upserts = ch().sentOfType('upsert_block');
      expect(upserts, isNotEmpty);
      expect(upserts.every((m) => m['title'] == '未同步' && m['id'] != 'old'), isTrue);
      // 确认后 pending 清空
      final pendingId = upserts.first['id'];
      ch().serverSend({
        'type': 'block_update',
        'block': serverBlock(
          pendingId as String,
          title: '未同步',
          seq: 2,
          updated: DateTime.now().millisecondsSinceEpoch,
          payload: {'markdown': 'x'},
        ),
      });
      await pump();
      final r = await future;
      expect(r.ok, isTrue, reason: r.error);
      expect(r.uploaded, 1);
      expect(c.pendingCount, 0);
    });

    test('离线时超时并给出明确原因', () async {
      // 不 connect
      final r = await c.syncNow(timeout: const Duration(milliseconds: 20));
      expect(r.ok, isFalse);
      expect(r.error, contains('未登录'));
    });

    test('resync 清空本地并请求从 0 同步', () async {
      c.connect('h:1', 'tok');
      await pump();
      ch().serverSend({'type': 'auth_ok', 'user_id': 'u', 'username': 'bill'});
      await pump();
      ch().serverSend({
        'type': 'block_update',
        'block': serverBlock('n1', title: '旧', seq: 4),
      });
      ch().serverSend({'type': 'sync_complete', 'latest_seq': 4});
      await pump();
      c.create(kind: BlockKind.note, title: '本地未同步');
      await pump();
      expect(c.byId('n1'), isNotNull);
      expect(c.pendingCount, 1);
      ch().sent.clear();

      ch().serverSend({'type': 'resync', 'latest_seq': 10});
      await pump();
      expect(c.byId('n1'), isNull);
      expect(c.pendingCount, 0);
      expect(c.lastSeq, 0);
      expect(c.catchingUp, isTrue);
      expect(ch().sentOfType('sync_since').last['since_seq'], 0);
    });
  });
}
