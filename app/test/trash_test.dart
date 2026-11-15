import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:syncnotes/app_scope.dart';
import 'package:syncnotes/blocks/builtin_types.dart';
import 'package:syncnotes/models/block.dart';
import 'package:syncnotes/services/auth_api.dart';
import 'package:syncnotes/services/settings.dart';
import 'package:syncnotes/sync/local_store.dart';
import 'package:syncnotes/sync/sync_client.dart';
import 'package:syncnotes/ui/block_card.dart';
import 'package:syncnotes/ui/theme.dart';
import 'package:syncnotes/ui/trash_page.dart';

void main() {
  setUpAll(registerBuiltinTypes);

  group('SyncClient 回收站', () {
    late SyncClient c;
    setUp(() => c = SyncClient(store: MemoryStore(), deviceId: 'pc'));

    test('delete moves to trash, hides everywhere, restore brings back', () {
      final m = c.create(kind: BlockKind.message, title: 'hi');
      expect(c.unreadCount, 0);
      c.delete(m.id);
      expect(c.blocks, isEmpty);
      expect(c.trash.single.id, m.id);
      expect(c.byId(m.id)!.deletedBy, 'pc');
      expect(c.outbox.last['deleted_at'], isNotNull);
      expect(c.restoreAll([m.id]), isEmpty);
      expect(c.blocks.single.id, m.id);
      expect(c.trash, isEmpty);
      expect(c.outbox.last.containsKey('deleted_at'), isTrue);
      expect(c.outbox.last['deleted_at'], isNull);
    });

    test('folder goes to trash with children; restore keeps structure', () {
      final f = c.create(kind: BlockKind.folder, title: 'f');
      final sub = c.create(kind: BlockKind.folder, title: 'sub', parentId: f.id);
      final k = c.create(kind: BlockKind.message, title: 'k', parentId: sub.id);
      c.delete(f.id);
      expect(c.blocks, isEmpty);
      expect(c.trash.map((b) => b.id), [f.id]);
      expect(c.trashChildCount(f.id), 2);
      c.restoreAll([f.id]);
      expect(c.childrenOf(f.id).single.id, sub.id);
      expect(c.childrenOf(sub.id).single.id, k.id);
    });

    test('restore when parent gone goes to root', () {
      final f = c.create(kind: BlockKind.folder, title: 'f');
      final k = c.create(kind: BlockKind.message, title: 'k', parentId: f.id);
      c.delete(k.id);
      c.delete(f.id);
      expect(c.trash.length, 2);
      expect(c.restoreAll([k.id]), [k.id]);
      expect(c.byId(k.id)!.parentId, isNull);
      expect(c.childrenOf(null).map((b) => b.id), [k.id]);
    });

    test('purge / empty trash tombstones descendants', () {
      final f = c.create(kind: BlockKind.folder, title: 'f');
      final k = c.create(kind: BlockKind.message, title: 'k', parentId: f.id);
      final m = c.create(kind: BlockKind.message, title: 'm');
      c.delete(f.id);
      c.delete(m.id);
      c.emptyTrash();
      expect(c.trash, isEmpty);
      expect(c.byId(k.id)!.deleted, isTrue);
      expect(c.byId(m.id)!.deleted, isTrue);
    });

    test('remote trash does not notify', () {
      final got = <Block>[];
      c.onRemoteNew = got.add;
      expect(Block.fromServer({'id': 'x', 'kind': 'note', 'deleted_at': 5, 'deleted_by': 'p'}).inTrash, isTrue);
    });
  });

  group('回收站界面', () {
    Future<SyncClient> pump(WidgetTester tester, {Size size = const Size(400, 760)}) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({'device_id': 'pc'});
      final settings = await Settings.load();
      final sync = SyncClient(store: MemoryStore(), deviceId: 'pc');
      await tester.pumpWidget(AppScope(
        services: AppServices(sync: sync, settings: settings, api: AuthApi(), logout: () async {}),
        child: MaterialApp(
          theme: buildAppTheme(Brightness.light),
          home: Navigator(onGenerateRoute: (_) => MaterialPageRoute(builder: (_) => const _Host())),
        ),
      ));
      return sync;
    }

    Future<void> openTrash(WidgetTester tester) async {
      await tester.tap(find.text('打开回收站'));
      await tester.pumpAndSettle();
    }

    testWidgets('delete -> appears in bin -> restore -> back in place', (tester) async {
      final sync = await pump(tester);
      final f = sync.create(kind: BlockKind.folder, title: '工作');
      final m = sync.create(kind: BlockKind.message, title: '会议纪要', parentId: f.id);
      sync.delete(m.id);
      await openTrash(tester);
      expect(find.text('会议纪要'), findsOneWidget);
      expect(find.textContaining('本设备'), findsOneWidget);
      expect(find.textContaining('刚刚删除'), findsOneWidget);
      expect(find.textContaining('30 天后自动彻底删除'), findsOneWidget);
      await tester.tap(find.byKey(Key('trashRestore-${m.id}')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('trashEmptyState')), findsOneWidget);
      expect(sync.childrenOf(f.id).single.id, m.id);
    });

    testWidgets('permanent delete with confirm', (tester) async {
      final sync = await pump(tester);
      final m = sync.create(kind: BlockKind.note, title: '草稿');
      sync.delete(m.id);
      await openTrash(tester);
      await tester.tap(find.byKey(Key('trashPurge-${m.id}')));
      await tester.pumpAndSettle();
      expect(find.text('彻底删除'), findsWidgets);
      await tester.tap(find.byKey(const Key('confirmDanger')));
      await tester.pumpAndSettle();
      expect(sync.byId(m.id)!.deleted, isTrue);
      expect(find.text('回收站是空的'), findsOneWidget);
    });

    testWidgets('empty bin', (tester) async {
      final sync = await pump(tester);
      for (final t in ['a', 'b', 'c']) {
        sync.delete(sync.create(kind: BlockKind.message, title: t).id);
      }
      await openTrash(tester);
      expect(find.byType(ListView), findsOneWidget);
      await tester.tap(find.byKey(const Key('trashEmpty')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('confirmDanger')));
      await tester.pumpAndSettle();
      expect(sync.trash, isEmpty);
      expect(find.text('回收站是空的'), findsOneWidget);
    });

    testWidgets('folder restore with children + multi-select batch', (tester) async {
      final sync = await pump(tester, size: const Size(1280, 800));
      final f = sync.create(kind: BlockKind.folder, title: '项目');
      final k1 = sync.create(kind: BlockKind.message, title: '子1', parentId: f.id);
      final k2 = sync.create(kind: BlockKind.note, title: '子2', parentId: f.id);
      final other = sync.create(kind: BlockKind.message, title: '其他');
      sync.delete(f.id);
      sync.delete(other.id);
      await openTrash(tester);
      expect(find.text('子1'), findsNothing);
      expect(find.textContaining('含 2 项'), findsOneWidget);
      await tester.tap(find.byKey(Key('trashSelect-${f.id}')));
      await tester.pump();
      await tester.tap(find.byKey(Key('trashSelect-${other.id}')));
      await tester.pumpAndSettle();
      expect(find.text('已选择 2 项'), findsOneWidget);
      await tester.tap(find.byKey(const Key('trashBatchRestore')));
      await tester.pumpAndSettle();
      expect(sync.trash, isEmpty);
      expect(sync.childrenOf(f.id).map((b) => b.id).toSet(), {k1.id, k2.id});
      expect(sync.childrenOf(null).map((b) => b.id).toSet(), {f.id, other.id});
    });

    testWidgets('undo toast restores (block menu)', (tester) async {
      final sync = await pump(tester);
      final m = sync.create(kind: BlockKind.message, title: '撤销我');
      await tester.tap(find.text('打开菜单'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('menuDelete')));
      await tester.pumpAndSettle();
      expect(sync.trash.single.id, m.id);
      await tester.tap(find.text('撤销'));
      await tester.pumpAndSettle();
      expect(sync.trash, isEmpty);
      expect(sync.blocks.single.id, m.id);
    });
  });
}

class _Host extends StatelessWidget {
  const _Host();
  @override
  Widget build(BuildContext context) {
    final sync = AppScope.of(context).sync;
    return Scaffold(
      body: Column(children: [
        TextButton(
          onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const TrashPage())),
          child: const Text('打开回收站'),
        ),
        TextButton(onPressed: () => showBlockMenu(context, sync.blocks.first), child: const Text('打开菜单')),
      ]),
    );
  }
}
