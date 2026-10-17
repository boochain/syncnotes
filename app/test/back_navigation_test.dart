import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:syncnotes/blocks/builtin_types.dart';
import 'package:syncnotes/main.dart';
import 'package:syncnotes/services/settings.dart';
import 'package:syncnotes/sync/local_store.dart';
import 'package:syncnotes/platform/notifications.dart';
import 'package:syncnotes/ui/back_handler.dart';

import 'fake_channel.dart';

/// Android 系统返回键行为：先关临时界面 → 返回上级 → 根页面“再按一次退出”。
void main() {
  setUpAll(registerBuiltinTypes);

  late List<MethodCall> platformCalls;

  Future<FakeChannel> pumpApp(WidgetTester tester, {bool loggedIn = true, Size size = const Size(400, 760)}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    platformCalls = [];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      platformCalls.add(call);
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    SharedPreferences.setMockInitialValues(loggedIn
        ? {'server': 'h:1', 'token': 'tok', 'username': 'bill', 'device_id': 'dev-b'}
        : {'device_id': 'dev-b'});
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
    if (!loggedIn) return FakeChannel();
    final ch = chans.first;
    ch.serverSend({'type': 'auth_ok', 'user_id': 'u', 'username': 'bill'});
    await tester.pump(const Duration(milliseconds: 50));
    ch.serverSend({'type': 'sync_complete', 'latest_seq': 0});
    await tester.pumpAndSettle();
    return ch;
  }

  int exits() => platformCalls.where((c) => c.method == 'SystemNavigator.pop').length;

  Future<void> back(WidgetTester tester) async {
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
  }

  Map<String, dynamic> block(String id, String kind, String title, int seq, {String? parent, Map<String, dynamic>? payload}) => {
        'id': id, 'kind': kind, 'title': title, 'payload': payload ?? {}, 'parent_id': parent,
        'viewed_mode': 'per_device', 'viewed_global': false, 'created_at': seq,
        'updated_at': seq, 'created_by': 'other', 'deleted': false, 'seq': seq
      };

  testWidgets('root: first back shows toast, second back within 2s exits', (tester) async {
    await pumpApp(tester);
    await back(tester);
    expect(find.text(BackToExit.message), findsOneWidget);
    expect(exits(), 0);
    expect(find.text('快速发送消息…'), findsOneWidget); // 应用仍在
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(exits(), 1);
  });

  testWidgets('root: exit window times out after 2s and re-arms', (tester) async {
    await pumpApp(tester);
    await back(tester);
    expect(find.text(BackToExit.message), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 2100));
    await tester.pumpAndSettle();
    expect(find.text(BackToExit.message), findsNothing); // 提示随窗口一起消失
    await back(tester);
    expect(exits(), 0); // 超时后第二次只是重新提示
    expect(find.text(BackToExit.message), findsOneWidget);
    await back(tester);
    expect(exits(), 1);
  });

  testWidgets('exit toast sits above the quick-send bar', (tester) async {
    await pumpApp(tester);
    await tester.binding.handlePopRoute();
    await tester.pump(const Duration(milliseconds: 500));
    final toast = tester.getRect(find.descendant(of: find.byType(SnackBar), matching: find.byType(Material)).first);
    final bar = tester.getRect(find.byKey(const Key('quickSendField')));
    expect(toast.bottom, lessThanOrEqualTo(bar.top));
  });

  testWidgets('bottom sheet (create menu) closes on back, app stays', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.byTooltip('新建'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('create-folder')), findsOneWidget);
    await back(tester);
    expect(find.byKey(const Key('create-folder')), findsNothing);
    expect(find.text(BackToExit.message), findsNothing);
    expect(exits(), 0);
  });

  testWidgets('dialog closes on back', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.byTooltip('新建'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('文件夹'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    await back(tester);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('快速发送消息…'), findsOneWidget);
    expect(exits(), 0);
  });

  testWidgets('drawer and search close before exiting', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.byKey(const Key('menuButton')));
    await tester.pumpAndSettle();
    expect(find.byType(Drawer), findsOneWidget);
    await back(tester);
    expect(find.byType(Drawer), findsNothing);

    await tester.tap(find.byKey(const Key('homeSearch')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('search')), findsOneWidget);
    await back(tester);
    expect(find.byKey(const ValueKey('search')), findsNothing);

    await tester.tap(find.byKey(const Key('filter-msg')));
    await tester.pumpAndSettle();
    await back(tester); // 非“全部”筛选 → 回到全部
    expect(find.text(BackToExit.message), findsNothing);
    await back(tester);
    expect(find.text(BackToExit.message), findsOneWidget);
    expect(exits(), 0);
  });

  testWidgets('settings page → back → home', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.byTooltip('设置'));
    await tester.pumpAndSettle();
    expect(find.text('退出登录', skipOffstage: false), findsOneWidget);
    await back(tester);
    expect(find.text('退出登录', skipOffstage: false), findsNothing);
    expect(find.byKey(const Key('homeTitle')), findsOneWidget);
    expect(exits(), 0);
  });

  testWidgets('nested folder → parent folder → home', (tester) async {
    final ch = await pumpApp(tester);
    ch.serverSend({'type': 'block_update', 'block': block('d', 'folder', '工作', 1)});
    ch.serverSend({'type': 'block_update', 'block': block('e', 'folder', '项目甲', 2, parent: 'd')});
    ch.serverSend({'type': 'block_update', 'block': block('m', 'message', '深层消息', 3, parent: 'e', payload: {'text': '深层'})});
    await tester.pumpAndSettle();
    await tester.tap(find.text('工作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('项目甲'));
    await tester.pumpAndSettle();
    expect(find.text('深层'), findsOneWidget);
    await back(tester);
    expect(find.text('深层'), findsNothing);
    expect(find.text('项目甲'), findsWidgets); // 回到上级文件夹“工作”
    expect(find.widgetWithText(AppBar, '工作'), findsOneWidget);
    await back(tester);
    expect(find.byKey(const Key('homeTitle')), findsOneWidget);
    expect(exits(), 0);
  });

  testWidgets('page editor: back unfocuses first, then returns to list; title kept', (tester) async {
    final ch = await pumpApp(tester);
    await tester.tap(find.byTooltip('新建'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('笔记'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('pageTitle')), '返回测试');
    await tester.pump(const Duration(milliseconds: 100)); // 防抖未到，返回时必须立即保存
    await back(tester); // 收起编辑焦点
    expect(find.byKey(const Key('pageTitle')), findsOneWidget);
    await back(tester); // 返回列表
    expect(find.byKey(const Key('pageTitle')), findsNothing);
    expect(find.byKey(const Key('homeTitle')), findsOneWidget);
    expect(ch.sentOfType('upsert_block').last['title'], '返回测试');
    expect(find.text('返回测试'), findsWidgets);
    expect(exits(), 0);
  });

  testWidgets('page "more" popup menu closes on back', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.byTooltip('新建'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('笔记'));
    await tester.pumpAndSettle();
    await back(tester); // 收起标题焦点
    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    expect(find.byType(PopupMenuItem<String>), findsWidgets);
    await back(tester);
    expect(find.byType(PopupMenuItem<String>), findsNothing);
    expect(find.byKey(const Key('pageTitle')), findsOneWidget); // 仍在页面
  });

  testWidgets('wide layout: open page → back → inbox → double-back exit', (tester) async {
    await pumpApp(tester, size: const Size(1200, 800));
    await tester.tap(find.byKey(const Key('newRootPage')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('pageTitle')), findsOneWidget);
    await back(tester); // 焦点
    await back(tester); // 页面 → 收件箱
    expect(find.byKey(const Key('pageTitle')), findsNothing);
    expect(find.text('收件箱'), findsWidgets);
    await back(tester);
    expect(find.text(BackToExit.message), findsOneWidget);
    await back(tester);
    expect(exits(), 1);
  });

  testWidgets('login screen: double-back to exit', (tester) async {
    await pumpApp(tester, loggedIn: false);
    expect(find.byKey(const Key('loginButton')), findsOneWidget);
    await back(tester);
    expect(find.text(BackToExit.message), findsOneWidget);
    expect(exits(), 0);
    await back(tester);
    expect(exits(), 1);
  });

  testWidgets('desktop: Esc closes the search field', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.byKey(const Key('homeSearch')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('search')), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('search')), findsNothing);
  });

  testWidgets('desktop: Ctrl+, opens settings', (tester) async {
    await pumpApp(tester, size: const Size(1200, 800));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.comma);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(find.text('退出登录', skipOffstage: false), findsOneWidget);
    await back(tester);
    expect(find.text('退出登录', skipOffstage: false), findsNothing);
  });

  testWidgets('tapping a notification opens that block; back returns home', (tester) async {
    final ch = await pumpApp(tester);
    ch.serverSend({'type': 'block_update', 'block': block('d', 'folder', '通知文件夹', 1)});
    ch.serverSend({'type': 'block_update', 'block': block('m', 'message', '里面', 2, parent: 'd', payload: {'text': '通知里的消息'})});
    await tester.pumpAndSettle();
    Notifier.opened.value = 'd';
    await tester.pumpAndSettle();
    expect(find.text('通知里的消息'), findsOneWidget);
    await back(tester);
    expect(find.text('通知里的消息'), findsNothing);
    expect(find.byKey(const Key('homeTitle')), findsOneWidget);
  });
}
