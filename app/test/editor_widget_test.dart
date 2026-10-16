import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:syncnotes/blocks/builtin_types.dart';
import 'package:syncnotes/main.dart';
import 'package:syncnotes/models/block.dart';
import 'package:syncnotes/pages/doc.dart';
import 'package:syncnotes/services/settings.dart';
import 'package:syncnotes/sync/local_store.dart';

import 'fake_channel.dart';

void main() {
  setUpAll(registerBuiltinTypes);

  Future<List<FakeChannel>> pumpApp(WidgetTester tester, {Size size = const Size(1200, 860)}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({'server': 'h:1', 'token': 'tok', 'username': 'bill', 'device_id': 'dev-e'});
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
    return chans;
  }

  Finder fields() => find.byWidgetPredicate(
      (w) => w is TextField && w.key is ValueKey<String> && (w.key as ValueKey<String>).value.startsWith('field-'));


  Future<void> newPage(WidgetTester tester, String title) async {
    await tester.tap(find.byKey(const Key('newRootPage')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('pageTitle')), title);
    await tester.pump(const Duration(milliseconds: 700));
    await tester.tap(find.byKey(const Key('pageFooter')));
    await tester.pumpAndSettle();
  }

  Future<void> type(WidgetTester tester, Finder f, String text) async {
    await tester.enterText(f, text);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
  }

  List<Map<String, dynamic>> upserts(FakeChannel ch, String kind) =>
      ch.sentOfType('upsert_block').where((m) => m['kind'] == kind).toList();

  testWidgets('wide layout shows sidebar; new page appears in tree and syncs', (tester) async {
    final chans = await pumpApp(tester);
    expect(find.byKey(const Key('sidebarInbox')), findsOneWidget);
    expect(find.text('还没有页面，点击 + 新建'), findsOneWidget);
    await newPage(tester, '周计划');
    expect(find.text('周计划'), findsWidgets); // 侧边栏树 + 标题
    expect(upserts(chans.first, 'page').last['title'], '周计划');
    expect(fields(), findsOneWidget);
  });

  testWidgets('markdown shortcut, Enter split, list continuation, todo check', (tester) async {
    final chans = await pumpApp(tester);
    await newPage(tester, '测试');
    await type(tester, fields().first, '# ');
    final ch = chans.first;
    expect(upserts(ch, 'text').last['payload']['type'], 'h1');
    await type(tester, fields().first, '大标题');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(fields(), findsNWidgets(2));
    await type(tester, fields().at(1), '[] ');
    expect(upserts(ch, 'text').last['payload']['type'], 'todo');
    await type(tester, fields().at(1), '买牛奶');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(fields(), findsNWidgets(3));
    // 新块延续待办类型
    expect(find.byWidgetPredicate((w) => w is Checkbox), findsNWidgets(2));
    await tester.tap(find.byWidgetPredicate((w) => w is Checkbox).first);
    await tester.pumpAndSettle();
    expect(upserts(ch, 'text').any((m) => m['payload']['checked'] == true && m['payload']['text'] == '买牛奶'), isTrue);
  });

  testWidgets('slash menu converts block type; Backspace merges; Ctrl+Z undoes', (tester) async {
    final chans = await pumpApp(tester);
    await newPage(tester, '斜杠');
    await type(tester, fields().first, '/代码');
    expect(find.byKey(const Key('slashMenu')), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('slashMenu')), findsNothing);
    expect(upserts(chans.first, 'text').last['payload']['type'], 'code');

    // 新页面：Enter 拆分后在第二行开头 Backspace 合并
    await newPage(tester, '合并');
    await type(tester, fields().first, 'AB');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(fields(), findsNWidgets(2));
    await type(tester, fields().at(1), 'CD');
    final f2 = tester.widget<TextField>(fields().at(1));
    f2.controller!.selection = const TextSelection.collapsed(offset: 0);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pumpAndSettle();
    expect(fields(), findsOneWidget);
    expect(tester.widget<TextField>(fields().first).controller!.text, 'ABCD');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(fields(), findsNWidgets(2));
  });

  testWidgets('Ctrl+K quick switcher opens a page', (tester) async {
    await pumpApp(tester);
    await newPage(tester, '甲页面');
    await newPage(tester, '乙页面');
    await tester.tap(find.byKey(const Key('sidebarInbox')));
    await tester.pumpAndSettle();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('quickSwitcher')), findsOneWidget);
    await tester.enterText(find.byKey(const Key('switcherField')), '甲');
    await tester.pumpAndSettle();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('quickSwitcher')), findsNothing);
    expect(tester.widget<TextField>(find.byKey(const Key('pageTitle'))).controller!.text, '甲页面');
  });

  testWidgets('nested pages show breadcrumbs and sidebar tree expands', (tester) async {
    await pumpApp(tester);
    await newPage(tester, '父页面');
    await type(tester, fields().first, '/子页面');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('breadcrumbs')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('breadcrumbs')), matching: find.textContaining('父页面')), findsOneWidget);
    // 点击面包屑回到父页面，父页面包含子页面链接行
    await tester.tap(find.descendant(of: find.byKey(const Key('breadcrumbs')), matching: find.textContaining('父页面')));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byKey(const Key('pageTitle'))).controller!.text, '父页面');
    expect(find.text('无标题'), findsWidgets);
  });

  testWidgets('narrow (phone) layout uses drawer and pushes page routes', (tester) async {
    await pumpApp(tester, size: const Size(400, 800));
    expect(find.byKey(const Key('sidebarInbox')), findsNothing);
    await tester.tap(find.byKey(const Key('menuButton')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('sidebarInbox')), findsOneWidget);
    await tester.tap(find.byKey(const Key('newRootPage')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('pageTitle')), findsOneWidget);
    expect(find.byType(BackButton), findsOneWidget);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text('快速发送消息…'), findsOneWidget);
  });

  testWidgets('inbox filter chips and empty state; theme switch', (tester) async {
    await pumpApp(tester);
    expect(find.byKey(const Key('emptyState')), findsOneWidget);
    await tester.enterText(find.byKey(const Key('quickSendField')), '一条消息');
    await tester.tap(find.byKey(const Key('quickSendButton')));
    await tester.pumpAndSettle();
    expect(find.text('一条消息'), findsWidgets);
    await tester.tap(find.byKey(const Key('filter-page')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('emptyState')), findsOneWidget);
    await tester.tap(find.byKey(const Key('filter-msg')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('emptyState')), findsNothing);

    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('深色'));
    await tester.pumpAndSettle();
    expect(Theme.of(tester.element(find.byKey(const Key('themeSelector')))).brightness, Brightness.dark);
  });

  test('DocType names are stable (wire format)', () {
    expect(DocType.values.map((e) => e.name), containsAll(['paragraph', 'h1', 'todo', 'code', 'image']));
    expect(BlockKind.values.map((e) => e.name), containsAll(['page', 'text']));
  });
}
