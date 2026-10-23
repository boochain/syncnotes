import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:syncnotes/models/block.dart';
import 'package:syncnotes/sync/local_store.dart';
import 'package:syncnotes/sync/sync_client.dart';

import 'fake_channel.dart';

Map<String, dynamic> serverBlock(String id,
        {String kind = 'message',
        String title = 't',
        Map<String, dynamic>? payload,
        int seq = 1,
        int updated = 1,
        String mode = 'per_device',
        bool viewedGlobal = false,
        String createdBy = 'other',
        String? parent,
        bool deleted = false}) =>
    {
      'id': id,
      'kind': kind,
      'title': title,
      'payload': payload ?? {'text': 'hi'},
      'parent_id': parent,
      'viewed_mode': mode,
      'viewed_global': viewedGlobal,
      'created_at': updated,
      'updated_at': updated,
      'created_by': createdBy,
      'deleted': deleted,
      'seq': seq,
    };

late List<FakeChannel> channels;
FakeChannel get ch => channels.last;

void main() {
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

  Future<void> pump() => Future<void>.delayed(const Duration(milliseconds: 5));

  Future<void> goOnline({int latest = 0}) async {
    ch.serverSend({'type': 'auth_ok', 'user_id': 'u', 'username': 'bill'});
    await pump();
    ch.serverSend({'type': 'sync_complete', 'latest_seq': latest});
    await pump();
  }

  test('wsUri normalizes addresses', () {
    expect(SyncClient.wsUri('192.168.1.5:7700').toString(), 'ws://192.168.1.5:7700/ws');
    expect(SyncClient.wsUri('http://h:1').toString(), 'ws://h:1/ws');
    expect(SyncClient.wsUri('https://notes.example.com').toString(), 'wss://notes.example.com/ws');
    expect(SyncClient.wsUri('ws://h:1/ws').toString(), 'ws://h:1/ws');
  });

  test('authenticates then requests catch-up from last seq', () async {
    c.connect('h:1', 'tok');
    await pump();
    expect(ch.sent.first, {'type': 'auth', 'token': 'tok', 'device_id': 'dev-a'});
    ch.serverSend({'type': 'auth_ok', 'user_id': 'u', 'username': 'bill'});
    await pump();
    expect(c.state, ConnState.online);
    expect(ch.sentOfType('sync_since').single['since_seq'], 0);
  });

  test('offline creates queue and replay in order after reconnect', () async {
    c.create(kind: BlockKind.message, title: 'a', payload: {'text': '1'});
    c.create(kind: BlockKind.note, title: 'b', payload: {'markdown': '2'});
    expect(c.pendingCount, 2);
    expect(c.blocks.length, 2);
    expect(c.blocks.every((b) => b.pending), isTrue);

    c.connect('h:1', 'tok');
    await pump();
    expect(ch.sentOfType('upsert_block'), isEmpty, reason: 'not sent before auth + catch-up');
    await goOnline();
    final ups = ch.sentOfType('upsert_block');
    expect(ups.map((u) => u['title']), ['a', 'b']);
    // 仍待确认，直到服务器回传
    expect(c.pendingCount, 2);
    for (final u in ups) {
      ch.serverSend({
        'type': 'block_update',
        'block': serverBlock(u['id'] as String,
            kind: u['kind'] as String,
            title: u['title'] as String,
            payload: Map<String, dynamic>.from(u['payload'] as Map),
            updated: u['client_updated_at'] as int,
            createdBy: 'dev-a',
            seq: 9),
      });
    }
    await pump();
    expect(c.pendingCount, 0);
    expect(c.blocks.every((b) => !b.pending), isTrue);
    expect(c.unreadCount, 0, reason: '自己发出的内容回声不应变成未读');
  });

  test('reordered payload keys do not mark an existing block unread', () async {
    c.connect('h:1', 't');
    await pump();
    await goOnline();
    final b = c.create(kind: BlockKind.file, title: 'a.bin', payload: {'z': 1, 'a': 'n', 'file_id': 'f'});
    await pump();
    final u = ch.sentOfType('upsert_block').last;
    ch.serverSend({
      'type': 'block_update',
      'block': serverBlock(b.id,
          kind: 'file',
          title: 'a.bin',
          payload: {'a': 'n', 'file_id': 'f', 'z': 1},
          updated: u['client_updated_at'] as int,
          createdBy: 'dev-a',
          seq: 4),
    });
    await pump();
    expect(c.pendingCount, 0);
    expect(c.byId(b.id)!.isViewed, isTrue);
    expect(c.unreadCount, 0);
  });

  test('repeated offline edits of one block collapse into one upsert', () async {
    final b = c.create(kind: BlockKind.note, title: 'n', payload: {'markdown': 'v1'});
    c.update(b.id, payload: {'markdown': 'v2'});
    c.update(b.id, payload: {'markdown': 'v3'});
    expect(c.pendingCount, 1);
    c.connect('h:1', 't');
    await pump();
    await goOnline();
    final ups = ch.sentOfType('upsert_block');
    expect(ups.length, 1);
    expect(ups.single['payload'], {'markdown': 'v3'});
  });

  test('outbox persists across restarts', () async {
    c.create(kind: BlockKind.message, title: 'persist me', payload: {'text': 'x'});
    await pump();
    final c2 = SyncClient(store: store, deviceId: 'dev-a', channelFactory: (_) => FakeChannel());
    await c2.loadLocal();
    expect(c2.pendingCount, 1);
    expect(c2.blocks.single.title, 'persist me');
    c2.dispose();
  });

  test('applies remote block updates and tracks seq', () async {
    c.connect('h:1', 't');
    await pump();
    await goOnline();
    var notified = <Block>[];
    c.onRemoteNew = notified.add;
    ch.serverSend({'type': 'block_update', 'block': serverBlock('r1', seq: 7)});
    await pump();
    expect(c.byId('r1')!.title, 't');
    expect(c.lastSeq, 7);
    expect(notified.single.id, 'r1');
    expect(c.unreadCount, 1);
  });

  test('catch-up blocks do not trigger notifications', () async {
    c.connect('h:1', 't');
    await pump();
    var notified = 0;
    c.onRemoteNew = (_) => notified++;
    ch.serverSend({'type': 'auth_ok', 'user_id': 'u', 'username': 'b'});
    await pump();
    ch.serverSend({'type': 'block_update', 'block': serverBlock('old', seq: 3)});
    ch.serverSend({'type': 'sync_complete', 'latest_seq': 3});
    await pump();
    expect(notified, 0);
    expect(c.byId('old'), isNotNull);
  });

  test('per-device viewed: only own device updates apply', () async {
    c.connect('h:1', 't');
    await pump();
    await goOnline();
    ch.serverSend({'type': 'block_update', 'block': serverBlock('p', seq: 1)});
    await pump();
    ch.serverSend({'type': 'viewed_update', 'block_id': 'p', 'viewed': true, 'device_id': 'other-dev', 'seq': 2});
    await pump();
    expect(c.byId('p')!.isViewed, isFalse);
    ch.serverSend({'type': 'viewed_update', 'block_id': 'p', 'viewed': true, 'device_id': 'dev-a', 'seq': 3});
    await pump();
    expect(c.byId('p')!.isViewed, isTrue);
  });

  test('global viewed: update without device applies everywhere', () async {
    c.connect('h:1', 't');
    await pump();
    await goOnline();
    ch.serverSend({'type': 'block_update', 'block': serverBlock('g', seq: 1, mode: 'global')});
    await pump();
    expect(c.byId('g')!.isViewed, isFalse);
    ch.serverSend({'type': 'viewed_update', 'block_id': 'g', 'viewed': true, 'device_id': null, 'seq': 2});
    await pump();
    expect(c.byId('g')!.isViewed, isTrue);
  });

  test('setViewed sends set_viewed and updates locally', () async {
    c.connect('h:1', 't');
    await pump();
    await goOnline();
    ch.serverSend({'type': 'block_update', 'block': serverBlock('x', seq: 1)});
    await pump();
    c.setViewed('x', true);
    expect(c.byId('x')!.isViewed, isTrue);
    expect(ch.sentOfType('set_viewed').single, {'type': 'set_viewed', 'block_id': 'x', 'viewed': true});
  });

  test('remote content change marks per-device block unread again', () async {
    c.connect('h:1', 't');
    await pump();
    await goOnline();
    ch.serverSend({'type': 'block_update', 'block': serverBlock('x', seq: 1)});
    await pump();
    c.setViewed('x', true);
    ch.serverSend({'type': 'block_update', 'block': serverBlock('x', seq: 2, updated: 5, payload: {'text': 'changed'})});
    await pump();
    expect(c.byId('x')!.isViewed, isFalse);
  });

  test('deleting a folder moves it (with children) to trash', () async {
    final f = c.create(kind: BlockKind.folder, title: 'f');
    c.create(kind: BlockKind.message, title: 'child', parentId: f.id);
    expect(c.childrenOf(f.id).length, 1);
    c.delete(f.id);
    expect(c.blocks, isEmpty);
  });

  test('reconnects with backoff after disconnect and catches up from lastSeq', () async {
    c.connect('h:1', 't');
    await pump();
    await goOnline(latest: 42);
    expect(c.lastSeq, 42);
    ch.serverClose();
    await pump();
    expect(c.state, isNot(ConnState.online));
    await Future<void>.delayed(const Duration(milliseconds: 600));
    expect(channels.length, greaterThanOrEqualTo(2));
    ch.serverSend({'type': 'auth_ok', 'user_id': 'u', 'username': 'b'});
    await pump();
    expect(ch.sentOfType('sync_since').single['since_seq'], 42);
  });

  test('auth error stops reconnecting', () async {
    c.connect('h:1', 'bad');
    await pump();
    ch.serverSend({'type': 'auth_error', 'message': '无效令牌'});
    await pump();
    expect(c.state, ConnState.authError);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(channels.length, 1);
  });

  test('stale server echo does not clobber newer pending local edit', () async {
    final b = c.create(kind: BlockKind.note, title: 'n', payload: {'markdown': 'local-new'});
    c.connect('h:1', 't');
    await pump();
    ch.serverSend({'type': 'auth_ok', 'user_id': 'u', 'username': 'b'});
    await pump();
    // catch-up delivers an older version of the same block
    final old = serverBlock(b.id, kind: 'note', payload: {'markdown': 'server-old'}, updated: b.updatedAt - 100, seq: 1);
    ch.serverSend({'type': 'block_update', 'block': old});
    await pump();
    expect(c.byId(b.id)!.payload['markdown'], 'local-new');
  });

  test('Block json roundtrip', () {
    final b = Block.fromServer(serverBlock('z', kind: 'file', payload: {'name': 'a.txt', 'size': 3}, parent: 'f'));
    final r = Block.fromJson(b.toJson());
    expect(r.kind, BlockKind.file);
    expect(r.parentId, 'f');
    expect(r.payload['name'], 'a.txt');
    expect(blockKindFrom('future_type'), BlockKind.unknown);
  });

  test('FileStore survives many concurrent saves and keeps latest', () async {
    final dir = await Directory.systemTemp.createTemp('sn-fs');
    final fs = FileStore(File('${dir.path}/c.json'));
    await Future.wait([for (var i = 0; i < 50; i++) fs.save({'i': i})]);
    expect((await fs.load())!['i'], 49);
    await dir.delete(recursive: true);
  });

  test('op sent on a silently dead connection is resent after reconnect', () async {
    c.connect('h:1', 't');
    await pump();
    await goOnline();
    final first = ch;
    final b = c.create(kind: BlockKind.message, title: 'lost?', payload: {'text': 'x'});
    expect(first.sentOfType('upsert_block').single['id'], b.id);
    // 服务器从未收到/确认就断开
    first.serverClose();
    await Future<void>.delayed(const Duration(milliseconds: 600));
    expect(channels.length, greaterThanOrEqualTo(2));
    await goOnline();
    expect(ch.sentOfType('upsert_block').map((u) => u['id']), contains(b.id));
    expect(c.pendingCount, 1);
  });

  test('heartbeat timeout forces reconnect on half-open connection', () async {
    final hb = SyncClient(
      store: MemoryStore(),
      deviceId: 'dev-h',
      pingInterval: const Duration(milliseconds: 40),
      maxBackoff: const Duration(milliseconds: 20),
      channelFactory: (_) {
        final f = FakeChannel();
        channels.add(f);
        return f;
      },
    );
    hb.connect('h:1', 't');
    await pump();
    ch.serverSend({'type': 'auth_ok', 'user_id': 'u', 'username': 'b'});
    await pump();
    final n = channels.length;
    // 服务器不再回应任何消息
    await Future<void>.delayed(const Duration(milliseconds: 800));
    expect(channels.length, greaterThan(n));
    hb.dispose();
  });

  test('set_viewed stays queued until confirmed', () async {
    c.connect('h:1', 't');
    await pump();
    await goOnline();
    ch.serverSend({'type': 'block_update', 'block': serverBlock('v', seq: 1)});
    await pump();
    c.setViewed('v', true);
    expect(c.pendingCount, 1);
    ch.serverSend({'type': 'viewed_update', 'block_id': 'v', 'viewed': true, 'device_id': 'dev-a', 'seq': 2});
    await pump();
    expect(c.pendingCount, 0);
  });

  test('cannot move a folder into its own descendant', () {
    final a = c.create(kind: BlockKind.folder, title: 'A');
    final b = c.create(kind: BlockKind.folder, title: 'B', parentId: a.id);
    c.update(a.id, parentId: b.id);
    expect(c.byId(a.id)!.parentId, isNull);
    c.update(a.id, parentId: a.id);
    expect(c.byId(a.id)!.parentId, isNull);
    expect(c.descendantIds(a.id), {b.id});
  });

  test('orphaned blocks (parent deleted/missing) show at root', () async {
    c.connect('h:1', 't');
    await pump();
    await goOnline();
    ch.serverSend({'type': 'block_update', 'block': serverBlock('kid', seq: 1, parent: 'ghost')});
    await pump();
    expect(c.childrenOf(null).map((b) => b.id), contains('kid'));
  });

  test('clearLocal(keepPending) keeps unsynced edits', () async {
    final b = c.create(kind: BlockKind.message, title: 'unsynced', payload: {'text': 'x'});
    await c.clearLocal(keepPending: true);
    expect(c.byId(b.id), isNotNull);
    expect(c.pendingCount, 1);
  });

  test('wsUri keeps reverse-proxy path prefix', () {
    expect(SyncClient.wsUri('https://h.com/notes').toString(), 'wss://h.com/notes/ws');
    expect(SyncClient.wsUri('https://h.com/notes/').toString(), 'wss://h.com/notes/ws');
  });
}
