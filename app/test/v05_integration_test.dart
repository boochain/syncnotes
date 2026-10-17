import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:syncnotes/app_scope.dart';
import 'package:syncnotes/blocks/builtin_types.dart';
import 'package:syncnotes/main.dart';
import 'package:syncnotes/models/block.dart';
import 'package:syncnotes/services/settings.dart';
import 'package:syncnotes/sync/local_store.dart';
import 'package:syncnotes/ui/back_handler.dart';
import 'package:syncnotes/ui/recovery_ui.dart';
import 'package:syncnotes/ui/theme.dart';

import 'fake_channel.dart';

/// v0.5 合并后：回收站 / 找回密码 / 恢复码对话框的返回键、标签、点击区。
void main() {
  setUpAll(registerBuiltinTypes);

  Future<void> pumpApp(WidgetTester tester, {bool loggedIn = true, Size size = const Size(400, 760)}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async => null);
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    SharedPreferences.setMockInitialValues(loggedIn
        ? {'server': 'h:1', 'token': 'tok', 'username': 'bill', 'device_id': 'dev-v'}
        : {'device_id': 'dev-v'});
    final settings = await Settings.load();
    await tester.pumpWidget(SyncNotesApp(settings: settings, store: MemoryStore(), channelFactory: (_) => FakeChannel()));
    await tester.pumpAndSettle();
  }

  Future<void> back(WidgetTester tester) async {
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
  }

  AppServices services(WidgetTester tester) => AppScope.of(tester.element(find.byKey(const Key('homeTitle'))));

  Future<void> openTrash(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('menuButton')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('sidebarTrash')));
    await tester.pumpAndSettle();
  }

  testWidgets('trash shows "页面" for page items; back exits multi-select first, then the page', (tester) async {
    await pumpApp(tester);
    final sync = services(tester).sync;
    final p = sync.create(kind: BlockKind.page, title: '会议纪要');
    final m = sync.create(kind: BlockKind.message, title: '一条消息', payload: {'text': '一条消息'});
    sync.delete(p.id);
    sync.delete(m.id);
    await tester.pumpAndSettle();
    await openTrash(tester);
    expect(find.textContaining('页面 · '), findsOneWidget);
    expect(find.textContaining('笔记 · '), findsNothing);

    await tester.tap(find.byKey(Key('trashSelect-${p.id}')));
    await tester.pumpAndSettle();
    expect(find.textContaining('已选择 1 项'), findsOneWidget);
    await back(tester); // 退出多选
    expect(find.textContaining('已选择'), findsNothing);
    expect(find.text('回收站'), findsWidgets);
    await back(tester); // 返回收件箱
    expect(find.byKey(const Key('homeTitle')), findsOneWidget);
    expect(find.text(BackToExit.message), findsNothing);
  });

  testWidgets('card "更多": visual 28, touch target 48, tap near the edge opens the menu', (tester) async {
    await pumpApp(tester);
    services(tester).sync.create(kind: BlockKind.message, title: 'hello', payload: {'text': 'hello'});
    await tester.pumpAndSettle();
    final more = find.byKey(const Key('cardMore'));
    final visual = tester.getRect(find.descendant(of: more, matching: find.byType(Material)).first);
    expect(visual.height, 28);
    expect(visual.width, 28);
    final hit = tester.getRect(more);
    expect(hit.width, greaterThanOrEqualTo(48));
    // 视觉按钮左侧 8px 处（原来点不到）
    await tester.tapAt(Offset(visual.left - 8, visual.center.dy));
    await tester.pumpAndSettle();
    expect(find.text('删除'), findsWidgets);
  });

  testWidgets('forgot-password page: back returns to login (not exit)', (tester) async {
    await pumpApp(tester, loggedIn: false);
    await tester.tap(find.byKey(const Key('forgotPasswordButton')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('forgotForm')), findsOneWidget);
    await back(tester);
    expect(find.byKey(const Key('forgotForm')), findsNothing);
    expect(find.byKey(const Key('loginButton')), findsOneWidget);
    expect(find.text(BackToExit.message), findsNothing);
  });

  testWidgets('forgot-password page: Esc returns to login (desktop)', (tester) async {
    await pumpApp(tester, loggedIn: false);
    await tester.tap(find.byKey(const Key('forgotPasswordButton')));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('loginButton')), findsOneWidget);
  });

  testWidgets('recovery-code dialog: back cannot dismiss until "已保存" is ticked', (tester) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async => null);
    late BuildContext ctx;
    await tester.pumpWidget(MaterialApp(theme: buildAppTheme(Brightness.light), home: Builder(builder: (c) {
      ctx = c;
      return const Scaffold();
    })));
    showRecoveryCodeDialog(ctx, code: 'ABCD-EFGH-IJKL', username: 'bill', server: 'h:1');
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('recoveryCodeDialog')), findsOneWidget);
    await back(tester);
    expect(find.byKey(const Key('recoveryCodeDialog')), findsOneWidget); // 未勾选：关不掉
    await tester.tap(find.byKey(const Key('recoveryAck')));
    await tester.pumpAndSettle();
    await back(tester);
    expect(find.byKey(const Key('recoveryCodeDialog')), findsNothing);
  });

  testWidgets('desktop: Ctrl+W closes the trash page', (tester) async {
    await pumpApp(tester, size: const Size(1200, 800));
    await tester.tap(find.byKey(const Key('sidebarTrash')));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(AppBar, '回收站'), findsOneWidget);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyW);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(find.widgetWithText(AppBar, '回收站'), findsNothing);
  });
}
