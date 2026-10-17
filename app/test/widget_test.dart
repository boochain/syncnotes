import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:syncnotes/blocks/block_type.dart';
import 'package:syncnotes/blocks/builtin_types.dart';
import 'package:syncnotes/main.dart';
import 'package:syncnotes/models/block.dart';
import 'package:syncnotes/services/settings.dart';
import 'package:syncnotes/sync/local_store.dart';

import 'fake_channel.dart';

void main() {
  setUpAll(registerBuiltinTypes);

  Future<(Settings, List<FakeChannel>)> pumpApp(WidgetTester tester,
      {bool loggedIn = true, MemoryStore? store, Size size = const Size(400, 760)}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues(loggedIn
        ? {'server': 'h:1', 'token': 'tok', 'username': 'bill', 'device_id': 'dev-w'}
        : {'device_id': 'dev-w'});
    final settings = await Settings.load();
    final chans = <FakeChannel>[];
    await tester.pumpWidget(SyncNotesApp(
      settings: settings,
      store: store ?? MemoryStore(),
      channelFactory: (_) {
        final f = FakeChannel();
        chans.add(f);
        return f;
      },
    ));
    await tester.pumpAndSettle();
    return (settings, chans);
  }

  testWidgets('shows login page when not logged in', (tester) async {
    await pumpApp(tester, loggedIn: false);
    expect(find.text('SyncNotes'), findsOneWidget);
    expect(find.byKey(const Key('serverField')), findsOneWidget);
    expect(find.byKey(const Key('loginButton')), findsOneWidget);
    // validation
    await tester.tap(find.byKey(const Key('loginButton')));
    await tester.pumpAndSettle();
    expect(find.text('请填写服务器地址、用户名和密码'), findsOneWidget);
    // toggle register mode
    await tester.tap(find.text('没有账号？注册'));
    await tester.pumpAndSettle();
    expect(find.text('注册并登录'), findsOneWidget);
  });

  testWidgets('auto-login with saved token goes to home and connects', (tester) async {
    final (_, chans) = await pumpApp(tester);
    expect(find.text('快速发送消息…'), findsOneWidget);
    expect(chans, isNotEmpty);
    expect(chans.first.sent.first['type'], 'auth');
    expect(chans.first.sent.first['token'], 'tok');
    expect(find.textContaining('连接中'), findsWidgets);
    chans.first.serverSend({'type': 'auth_ok', 'user_id': 'u', 'username': 'bill'});
    await tester.pump(const Duration(milliseconds: 50));
    chans.first.serverSend({'type': 'sync_complete', 'latest_seq': 0});
    await tester.pumpAndSettle();
    expect(find.byTooltip('在线'), findsOneWidget);
  });

  testWidgets('quick send creates a message block and sends upsert', (tester) async {
    final (_, chans) = await pumpApp(tester);
    chans.first.serverSend({'type': 'auth_ok', 'user_id': 'u', 'username': 'bill'});
    await tester.pump(const Duration(milliseconds: 50));
    chans.first.serverSend({'type': 'sync_complete', 'latest_seq': 0});
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('quickSendField')), '你好，世界');
    await tester.tap(find.byKey(const Key('quickSendButton')));
    await tester.pumpAndSettle();
    expect(find.text('你好，世界'), findsWidgets);
    final up = chans.first.sentOfType('upsert_block').single;
    expect(up['kind'], 'message');
    expect(up['payload'], {'text': '你好，世界'});
  });

  testWidgets('offline quick send shows pending count', (tester) async {
    await pumpApp(tester);
    await tester.enterText(find.byKey(const Key('quickSendField')), 'offline msg');
    await tester.tap(find.byKey(const Key('quickSendButton')));
    await tester.pumpAndSettle();
    expect(find.textContaining('1 待同步'), findsWidgets);
    expect(find.byTooltip('等待同步'), findsOneWidget);
  });

  testWidgets('remote blocks render with type-specific previews; folders first', (tester) async {
    final (_, chans) = await pumpApp(tester);
    final ch = chans.first;
    ch.serverSend({'type': 'auth_ok', 'user_id': 'u', 'username': 'bill'});
    await tester.pump(const Duration(milliseconds: 50));
    Map<String, dynamic> b(String id, String kind, String title, Map<String, dynamic> p, int seq,
            {String? parent}) =>
        {
          'id': id, 'kind': kind, 'title': title, 'payload': p, 'parent_id': parent,
          'viewed_mode': 'per_device', 'viewed_global': false, 'created_at': seq,
          'updated_at': seq, 'created_by': 'other', 'deleted': false, 'seq': seq
        };
    ch.serverSend({'type': 'block_update', 'block': b('m', 'message', '消息标题', {'text': '消息正文'}, 1)});
    ch.serverSend({'type': 'block_update', 'block': b('n', 'note', '笔记标题', {'markdown': '**粗体**'}, 2)});
    ch.serverSend({'type': 'block_update', 'block': b('f', 'file', 'doc.pdf', {'name': 'doc.pdf', 'size': 2048}, 3)});
    ch.serverSend({'type': 'block_update', 'block': b('d', 'folder', '工作', {}, 4)});
    ch.serverSend({'type': 'block_update', 'block': b('c', 'message', '子消息', {'text': 'in folder'}, 5, parent: 'd')});
    ch.serverSend({'type': 'sync_complete', 'latest_seq': 5});
    await tester.pumpAndSettle();

    expect(find.text('消息正文'), findsOneWidget);
    expect(find.text('粗体'), findsOneWidget); // markdown stripped to plain preview
    expect(find.textContaining('PDF · 2.0 KB'), findsOneWidget);
    expect(find.textContaining('1 项'), findsOneWidget); // folder preview
    expect(find.text('子消息'), findsNothing); // child hidden at root
    // folder listed first
    final folderY = tester.getTopLeft(find.text('工作')).dy;
    final msgY = tester.getTopLeft(find.text('消息标题')).dy;
    expect(folderY, lessThan(msgY));

    // open folder → child visible
    await tester.tap(find.text('工作'));
    await tester.pumpAndSettle();
    expect(find.text('子消息'), findsOneWidget);
  });

  testWidgets('tapping a message copies and marks viewed', (tester) async {
    final (_, chans) = await pumpApp(tester);
    final ch = chans.first;
    ch.serverSend({'type': 'auth_ok', 'user_id': 'u', 'username': 'bill'});
    await tester.pump(const Duration(milliseconds: 50));
    ch.serverSend({'type': 'block_update', 'block': {
      'id': 'm', 'kind': 'message', 'title': 'hello', 'payload': {'text': 'body'}, 'parent_id': null,
      'viewed_mode': 'global', 'viewed_global': false, 'created_at': 1, 'updated_at': 1,
      'created_by': 'other', 'deleted': false, 'seq': 1}});
    ch.serverSend({'type': 'sync_complete', 'latest_seq': 1});
    await tester.pumpAndSettle();
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async => null);
    await tester.tap(find.text('body'));
    await tester.pumpAndSettle();
    expect(find.text('已复制到剪贴板'), findsOneWidget);
    expect(ch.sentOfType('set_viewed').single['block_id'], 'm');
  });

  testWidgets('"笔记" creates a Notion-style page', (tester) async {
    final (_, chans) = await pumpApp(tester);
    final ch = chans.first;
    ch.serverSend({'type': 'auth_ok', 'user_id': 'u', 'username': 'bill'});
    await tester.pump(const Duration(milliseconds: 50));
    ch.serverSend({'type': 'sync_complete', 'latest_seq': 0});
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('新建'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('笔记'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('pageTitle')), findsOneWidget);
    await tester.enterText(find.byKey(const Key('pageTitle')), '会议记录');
    await tester.pump(const Duration(milliseconds: 700)); // debounce
    await tester.pumpAndSettle();
    final ups = ch.sentOfType('upsert_block');
    expect(ups.first['kind'], 'page');
    expect(ups.last['title'], '会议记录');
  });

  testWidgets('settings page shows viewed-mode and autostart options', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.byTooltip('设置'));
    await tester.pumpAndSettle();
    // 设置项变多（回收站、找回密码、关闭到托盘……），往下滚动查找
    await tester.scrollUntilVisible(find.text('新建块默认使用全局已读'), 200);
    expect(find.text('新建块默认使用全局已读'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('登录系统时自动启动'), 200);
    expect(find.text('登录系统时自动启动'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('退出登录'), 200);
    expect(find.text('退出登录'), findsOneWidget);
  });

  test('block type registry covers all kinds with Chinese labels', () {
    for (final k in BlockKind.values) {
      if (k == BlockKind.text) continue; // 页面内容块，由页面编辑器渲染
      expect(BlockTypes.of(k).kind, k);
    }
    expect(BlockTypes.creatable.map((t) => t.label), containsAll(['消息', '笔记', '文件', '文件夹']));
  });

  testWidgets('Enter confirms the new-folder dialog', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.byTooltip('新建'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('文件夹'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, '项目');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.text('项目'), findsOneWidget);
  });

  testWidgets('Material widgets use Chinese localization', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.byTooltip('设置'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.textContaining('关于'), 200);
    expect(find.textContaining('关于'), findsOneWidget);
  });
}
