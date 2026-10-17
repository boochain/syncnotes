// 跨栈端到端测试：启动真实 Rust 服务器，两个 Dart 同步客户端互相同步。
// 需要环境变量 SYNCNOTES_SERVER_BIN 指向已构建的服务器二进制，否则跳过。
@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:syncnotes/models/block.dart';
import 'package:syncnotes/services/auth_api.dart';
import 'package:syncnotes/sync/local_store.dart';
import 'package:syncnotes/sync/sync_client.dart';

Future<void> waitFor(bool Function() cond, {Duration timeout = const Duration(seconds: 5)}) async {
  final end = DateTime.now().add(timeout);
  while (!cond()) {
    if (DateTime.now().isAfter(end)) throw TimeoutException('condition not met');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  final bin = Platform.environment['SYNCNOTES_SERVER_BIN'];
  Process? server;
  late String addr;
  late Directory tmp;

  setUpAll(() async {
    if (bin == null) return;
    tmp = await Directory.systemTemp.createTemp('syncnotes-e2e');
    final port = 17000 + (DateTime.now().millisecondsSinceEpoch % 2000);
    addr = '127.0.0.1:$port';
    server = await Process.start(bin, [
      '--bind', addr, '--db', '${tmp.path}/t.db', '--files-dir', '${tmp.path}/files', '--mdns', 'false'
    ]);
    server!.stderr.drain();
    server!.stdout.drain();
    final api = AuthApi();
    await waitFor(() => false, timeout: const Duration(milliseconds: 1)).catchError((_) {});
    for (var i = 0; i < 50; i++) {
      try {
        await api.register(addr, 'bill', 'pass1234');
        break;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
  });

  tearDownAll(() async {
    server?.kill();
  });

  test('two clients sync in real time, offline edits replay, viewed modes', () async {
    if (bin == null) {
      markTestSkipped('SYNCNOTES_SERVER_BIN not set');
      return;
    }
    final api = AuthApi();
    final ta = await api.login(addr, 'bill', 'pass1234', 'pc');
    final tb = await api.login(addr, 'bill', 'pass1234', 'phone');
    final a = SyncClient(store: MemoryStore(), deviceId: 'pc');
    final b = SyncClient(store: MemoryStore(), deviceId: 'phone');
    final notifiedB = <Block>[];
    b.onRemoteNew = notifiedB.add;
    a.connect(addr, ta.token);
    b.connect(addr, tb.token);
    await waitFor(() => a.state == ConnState.online && b.state == ConnState.online);
    await Future<void>.delayed(const Duration(milliseconds: 100));

    // 1. realtime create
    final m = a.create(kind: BlockKind.message, title: 'hi', payload: {'text': '来自电脑'}, viewedMode: ViewedMode.global);
    await waitFor(() => b.byId(m.id) != null);
    expect(b.byId(m.id)!.payload['text'], '来自电脑');
    expect(notifiedB.map((x) => x.id), contains(m.id));

    // 2. realtime edit back
    b.update(m.id, payload: {'text': '手机改了'});
    await waitFor(() => a.byId(m.id)!.payload['text'] == '手机改了');

    // 3. global viewed
    b.setViewed(m.id, true);
    await waitFor(() => a.byId(m.id)!.isViewed);

    // 4. per-device viewed stays independent
    final n = a.create(kind: BlockKind.note, title: 'n', payload: {'markdown': '# x'}, viewedMode: ViewedMode.perDevice);
    await waitFor(() => b.byId(n.id) != null);
    expect(b.byId(n.id)!.isViewed, isFalse);
    b.setViewed(n.id, true);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(a.byId(n.id)!.isViewed, isTrue, reason: 'creator sees own block as viewed locally');
    expect(b.byId(n.id)!.isViewed, isTrue);

    // 5. offline: phone disconnects, both edit, phone reconnects
    b.disconnect();
    final offline = b.create(kind: BlockKind.message, title: 'queued', payload: {'text': '离线消息'});
    expect(b.pendingCount, 1);
    final whileAway = a.create(kind: BlockKind.message, title: 'away', payload: {'text': '你不在时'});
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(a.byId(offline.id), isNull);
    b.connect(addr, tb.token);
    await waitFor(() => a.byId(offline.id) != null && b.byId(whileAway.id) != null);
    expect(b.pendingCount, 0);

    // 6. delete on A → shows in B's recycle bin; restore & purge propagate
    a.delete(m.id);
    await waitFor(() => b.trash.any((x) => x.id == m.id));
    expect(b.blocks.any((x) => x.id == m.id), isFalse);
    expect(b.byId(m.id)!.deletedBy, 'pc');
    b.restoreAll([m.id]);
    await waitFor(() => a.byId(m.id)!.deletedAt == null && a.blocks.any((x) => x.id == m.id));
    a.delete(m.id);
    await waitFor(() => b.trash.any((x) => x.id == m.id));
    b.purge([m.id]);
    await waitFor(() => a.byId(m.id)!.deleted);

    a.dispose();
    b.dispose();
  });
}
