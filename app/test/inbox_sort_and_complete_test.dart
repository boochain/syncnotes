import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:syncnotes/blocks/builtin_types.dart';
import 'package:syncnotes/main.dart';
import 'package:syncnotes/models/block.dart';
import 'package:syncnotes/services/settings.dart';
import 'package:syncnotes/sync/local_store.dart';
import 'package:syncnotes/ui/block_card.dart';

import 'fake_channel.dart';

Block _block(
  String id, {
  BlockKind kind = BlockKind.note,
  int createdAt = 100,
  int updatedAt = 100,
  Map<String, dynamic> payload = const {},
}) =>
    Block(
      id: id,
      kind: kind,
      title: id,
      payload: payload,
      createdAt: createdAt,
      updatedAt: updatedAt,
    );

void main() {
  setUpAll(registerBuiltinTypes);

  test('compareInboxBlocks sorts by completion, then priority, then createdAt', () {
    final items = [
      _block('default-old', createdAt: 10, updatedAt: 999),
      _block('default-new', createdAt: 30, updatedAt: 30),
      _block('todo-blue', createdAt: 5, payload: {'sticky_color': 'blue'}),
      _block('urgent-red', createdAt: 1, payload: {'sticky_color': 'red'}),
      _block('important-amber', createdAt: 20, payload: {'sticky_color': 'amber'}),
      _block('done-urgent', createdAt: 999, payload: {'sticky_color': 'red', 'completed': true}),
      _block('done-default', createdAt: 500, payload: {'completed': true}),
    ];

    items.sort(compareInboxBlocks);
    expect(
      items.map((b) => b.id).toList(),
      [
        'urgent-red',
        'important-amber',
        'todo-blue',
        'default-new',
        'default-old',
        'done-urgent',
        'done-default',
      ],
    );
  });

  testWidgets('toggling complete moves item to bottom completed section and keeps unfinished first', (tester) async {
    tester.view.physicalSize = const Size(420, 860);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    SharedPreferences.setMockInitialValues({
      'server': 'h:1',
      'token': 'tok',
      'username': 'bill',
      'device_id': 'dev-sort',
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

    final ch = chans.first;
    ch.serverSend({'type': 'auth_ok', 'user_id': 'u', 'username': 'bill'});
    await tester.pump(const Duration(milliseconds: 50));

    void send(String id, String title, int createdAt, Map<String, dynamic> payload, int seq) {
      ch.serverSend({
        'type': 'block_update',
        'block': {
          'id': id,
          'kind': 'note',
          'title': title,
          'payload': payload,
          'parent_id': null,
          'viewed_mode': 'per_device',
          'viewed_global': false,
          'created_at': createdAt,
          'updated_at': createdAt,
          'created_by': 'u',
          'deleted': false,
          'seq': seq,
        },
      });
    }

    send('n-normal', '普通笔记', 200, {'markdown': 'normal'}, 1);
    send('n-urgent', '紧急笔记', 100, {'markdown': 'urgent', 'sticky_color': 'red'}, 2);
    ch.serverSend({'type': 'sync_complete', 'latest_seq': 2});
    await tester.pumpAndSettle();

    // 紧急笔记优先级更高，排在创建时间更新的普通笔记之前
    final urgentTopBefore = tester.getTopLeft(find.byKey(const ValueKey('card-n-urgent'))).dy;
    final normalTopBefore = tester.getTopLeft(find.byKey(const ValueKey('card-n-normal'))).dy;
    expect(urgentTopBefore, lessThan(normalTopBefore));
    expect(find.byKey(const Key('completedSectionHeader')), findsNothing);

    // 勾选“紧急笔记”为已完成 → 自动沉底进入单独的“已完成”分区，未完成的普通笔记保持在最前
    await tester.tap(find.byKey(const ValueKey('completeToggle-n-urgent')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('completedSectionHeader')), findsOneWidget);
    final normalTopAfter = tester.getTopLeft(find.byKey(const ValueKey('card-n-normal'))).dy;
    final headerTop = tester.getTopLeft(find.byKey(const Key('completedSectionHeader'))).dy;
    final urgentTopAfter = tester.getTopLeft(find.byKey(const ValueKey('card-n-urgent'))).dy;
    expect(normalTopAfter, lessThan(headerTop));
    expect(headerTop, lessThan(urgentTopAfter));

    // 取消完成 → 紧急笔记立即回到最前且已完成分区消失
    await tester.tap(find.byKey(const ValueKey('completeToggle-n-urgent')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('completedSectionHeader')), findsNothing);
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('card-n-urgent'))).dy,
      lessThan(tester.getTopLeft(find.byKey(const ValueKey('card-n-normal'))).dy),
    );
  });
}
