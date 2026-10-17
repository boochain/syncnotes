import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:syncnotes/blocks/builtin_types.dart';
import 'package:syncnotes/main.dart';
import 'package:syncnotes/models/block.dart';
import 'package:syncnotes/services/auth_api.dart';
import 'package:syncnotes/services/data_export.dart';
import 'package:syncnotes/services/settings.dart';
import 'package:syncnotes/sync/local_store.dart';
import 'package:syncnotes/sync/sync_client.dart';
import 'package:syncnotes/ui/recovery_ui.dart';
import 'package:syncnotes/ui/theme.dart';

import 'fake_channel.dart';

const code = 'ABCDE-FGHIJ-KLMNO-PQRST';

Map<String, dynamic> auth({String? recovery, bool has = true, bool must = false}) => {
      'token': 'new-tok',
      'user_id': 'u1',
      'username': 'bill',
      'recovery_code': ?recovery,
      'has_recovery_code': has,
      'must_change_password': must,
    };

http.Response js(Object o, [int st = 200]) =>
    http.Response.bytes(utf8.encode(jsonEncode(o)), st, headers: {'content-type': 'application/json'});

Widget wrap(Widget child, {Brightness b = Brightness.light}) =>
    MaterialApp(theme: buildAppTheme(b), home: child);

void main() {
  setUpAll(registerBuiltinTypes);

  group('恢复码对话框', () {
    testWidgets('显示一次、复制、保存到文件、勾选后才能完成', (tester) async {
      String? clip;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') clip = (call.arguments as Map)['text'] as String;
        return null;
      });
      String? savedName;
      Uint8List? savedBytes;
      fileSaver = (name, bytes) async {
        savedName = name;
        savedBytes = bytes;
        return '/tmp/$name';
      };
      addTearDown(() => fileSaver = defaultFileSaver);
      var closed = false;
      await tester.pumpWidget(wrap(Builder(
        builder: (c) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () async {
                await showRecoveryCodeDialog(c, code: code, username: 'bill', server: 'h:1');
                closed = true;
              },
              child: const Text('open'),
            ),
          ),
        ),
      )));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('recoveryCodeDialog')), findsOneWidget);
      expect(find.text(code), findsOneWidget);
      expect(find.textContaining('只显示这一次'), findsOneWidget);
      // 未确认时不能关闭（按钮禁用，点遮罩无效）
      expect(tester.widget<FilledButton>(find.byKey(const Key('recoveryDone'))).onPressed, isNull);
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('recoveryCodeDialog')), findsOneWidget);

      await tester.tap(find.byKey(const Key('copyRecoveryCode')));
      await tester.pump();
      expect(clip, code);
      await tester.pump(const Duration(seconds: 4));

      await tester.tap(find.byKey(const Key('saveRecoveryCode')));
      await tester.pumpAndSettle();
      expect(savedName, 'SyncNotes-恢复码-bill.txt');
      final txt = utf8.decode(savedBytes!);
      expect(txt, contains(code));
      expect(txt, contains('用户名：bill'));
      // 保存成功自动勾选
      expect(tester.widget<FilledButton>(find.byKey(const Key('recoveryDone'))).onPressed, isNotNull);
      await tester.tap(find.byKey(const Key('recoveryDone')));
      await tester.pumpAndSettle();
      expect(closed, isTrue);
    });

    testWidgets('手机宽度不溢出（深色）', (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(wrap(const RecoveryCodeDialog(code: code, username: 'bill', server: 'h:1'), b: Brightness.dark));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const Key('recoveryAck')));
      await tester.pump();
      expect(tester.widget<FilledButton>(find.byKey(const Key('recoveryDone'))).onPressed, isNotNull);
    });
  });

  group('忘记密码页', () {
    Future<List<http.Request>> pumpForgot(WidgetTester tester, http.Response Function(http.Request) h,
        {Size size = const Size(390, 844)}) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final reqs = <http.Request>[];
      final api = AuthApi(client: MockClient((r) async {
        reqs.add(r);
        return h(r);
      }));
      await tester.pumpWidget(wrap(ForgotPasswordPage(api: api, server: 'h:1', username: 'bill', deviceId: 'dev-1')));
      await tester.pumpAndSettle();
      return reqs;
    }

    Future<void> fill(WidgetTester tester, {String c = code, String p1 = 'newpass', String? p2}) async {
      await tester.enterText(find.descendant(of: find.byKey(const Key('recoveryCodeField')), matching: find.byType(TextField)), c);
      await tester.enterText(find.descendant(of: find.byKey(const Key('forgotNewPassword')), matching: find.byType(TextField)), p1);
      await tester.enterText(
          find.descendant(of: find.byKey(const Key('forgotConfirmPassword')), matching: find.byType(TextField)), p2 ?? p1);
    }

    testWidgets('校验：缺少恢复码、密码不一致、过短', (tester) async {
      final reqs = await pumpForgot(tester, (_) => js(auth()));
      await tester.tap(find.byKey(const Key('resetPasswordButton')));
      await tester.pumpAndSettle();
      expect(find.text('请填写服务器地址、用户名和恢复码'), findsOneWidget);
      await fill(tester, p1: 'abcd', p2: 'abce');
      await tester.tap(find.byKey(const Key('resetPasswordButton')));
      await tester.pumpAndSettle();
      expect(find.text('两次输入的新密码不一致'), findsOneWidget);
      await fill(tester, p1: 'ab');
      await tester.tap(find.byKey(const Key('resetPasswordButton')));
      await tester.pumpAndSettle();
      expect(find.text('新密码至少 4 位'), findsOneWidget);
      expect(reqs, isEmpty);
    });

    testWidgets('恢复码错误 / 限流显示服务器提示', (tester) async {
      var n = 0;
      await pumpForgot(tester, (_) => n++ == 0 ? http.Response.bytes(utf8.encode('用户名或恢复码错误'), 401) : http.Response('', 429));
      await fill(tester);
      await tester.tap(find.byKey(const Key('resetPasswordButton')));
      await tester.pumpAndSettle();
      expect(find.text('用户名或恢复码错误'), findsOneWidget);
      await tester.tap(find.byKey(const Key('resetPasswordButton')));
      await tester.pumpAndSettle();
      expect(find.text('尝试次数过多，请 15 分钟后再试'), findsOneWidget);
    });

    testWidgets('成功：发送正确请求，显示新恢复码，返回登录结果', (tester) async {
      final reqs = await pumpForgot(tester, (_) => js(auth(recovery: 'ZZZZZ-YYYYY-XXXXX-WWWWW')));
      await fill(tester, c: 'abcde fghij klmno pqrst');
      await tester.tap(find.byKey(const Key('resetPasswordButton')));
      await tester.pumpAndSettle();
      expect(reqs.single.url.path, '/api/recover');
      final body = jsonDecode(reqs.single.body) as Map;
      expect(body['username'], 'bill');
      expect(body['recovery_code'], 'abcde fghij klmno pqrst');
      expect(body['new_password'], 'newpass');
      expect(body['device_id'], 'dev-1');
      expect(find.text('ZZZZZ-YYYYY-XXXXX-WWWWW'), findsOneWidget);
      await tester.tap(find.byKey(const Key('recoveryAck')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('recoveryDone')));
      await tester.pumpAndSettle();
    });

    testWidgets('桌面宽度布局居中且不溢出', (tester) async {
      await pumpForgot(tester, (_) => js(auth()), size: const Size(1280, 800));
      expect(tester.takeException(), isNull);
      final form = tester.getRect(find.byKey(const Key('forgotForm')));
      expect(form.width, 360);
      expect((form.center.dx - 640).abs(), lessThan(1));
    });
  });

  group('登录页集成', () {
    Future<(Settings, List<http.Request>)> pumpLogin(WidgetTester tester, http.Response Function(http.Request) h,
        {Map<String, Object> prefs = const {}}) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({'device_id': 'dev-w', ...prefs});
      final settings = await Settings.load();
      final reqs = <http.Request>[];
      await tester.pumpWidget(SyncNotesApp(
        settings: settings,
        store: MemoryStore(),
        api: AuthApi(client: MockClient((r) async {
          reqs.add(r);
          return h(r);
        })),
        channelFactory: (_) => FakeChannel(),
      ));
      await tester.pumpAndSettle();
      return (settings, reqs);
    }

    Future<void> login(WidgetTester tester, {String pw = 'temp'}) async {
      await tester.enterText(find.byKey(const Key('serverField')), 'h:1');
      await tester.enterText(find.byKey(const Key('userField')), 'bill');
      await tester.enterText(find.byKey(const Key('passwordField')), pw);
      await tester.tap(find.byKey(const Key('loginButton')));
      await tester.pumpAndSettle();
    }

    testWidgets('「忘记密码？」打开忘记密码页并带入用户名', (tester) async {
      await pumpLogin(tester, (_) => js(auth()));
      await tester.enterText(find.byKey(const Key('userField')), 'bill');
      await tester.tap(find.byKey(const Key('forgotPasswordButton')));
      await tester.pumpAndSettle();
      expect(find.text('用恢复码重置密码'), findsOneWidget);
      expect(find.widgetWithText(TextField, 'bill'), findsOneWidget);
    });

    testWidgets('临时密码登录后强制修改密码，取消则不保存登录', (tester) async {
      final (settings, reqs) = await pumpLogin(tester, (r) => r.url.path == '/api/login' ? js(auth(must: true)) : http.Response('', 204));
      await login(tester);
      expect(find.byKey(const Key('changePasswordDialog')), findsOneWidget);
      expect(find.text('请设置新密码'), findsOneWidget);
      await tester.tap(find.text('返回登录'));
      await tester.pumpAndSettle();
      expect(settings.token, isNull);
      expect(find.byKey(const Key('loginButton')), findsOneWidget);

      await login(tester);
      await tester.enterText(find.descendant(of: find.byKey(const Key('newPasswordField')), matching: find.byType(TextField)), 'mine1');
      await tester.enterText(find.descendant(of: find.byKey(const Key('confirmPasswordField')), matching: find.byType(TextField)), 'mine1');
      await tester.tap(find.byKey(const Key('changePasswordSubmit')));
      await tester.pumpAndSettle();
      final change = reqs.lastWhere((r) => r.url.path == '/api/change-password');
      expect(jsonDecode(change.body), {'old_password': 'temp', 'new_password': 'mine1'});
      expect(change.headers['authorization'], 'Bearer new-tok');
      expect(settings.token, 'new-tok');
    });

    testWidgets('旧账号没有恢复码：只提示一次，可立即生成', (tester) async {
      final (settings, reqs) = await pumpLogin(tester, (r) => switch (r.url.path) {
            '/api/login' => js(auth(has: false)),
            '/api/recovery-code' => js({'recovery_code': code}),
            _ => http.Response('', 204),
          });
      await login(tester, pw: 'pw12');
      expect(find.byKey(const Key('legacyRecoveryPrompt')), findsOneWidget);
      await tester.tap(find.byKey(const Key('legacyGenerate')));
      await tester.pumpAndSettle();
      expect(jsonDecode(reqs.last.body), {'password': 'pw12'});
      expect(find.text(code), findsOneWidget);
      await tester.tap(find.byKey(const Key('recoveryAck')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('recoveryDone')));
      await tester.pumpAndSettle();
      expect(settings.token, 'new-tok');
      expect(legacyPromptShown(settings, 'bill'), isTrue);
    });

    testWidgets('注册后显示恢复码', (tester) async {
      await pumpLogin(tester, (r) => r.url.path == '/api/register' ? js(auth(recovery: code)) : js(auth()));
      await tester.tap(find.text('没有账号？注册'));
      await tester.pumpAndSettle();
      await login(tester, pw: 'pw12');
      expect(find.byKey(const Key('recoveryCodeDialog')), findsOneWidget);
      expect(find.text(code), findsOneWidget);
    });
  });

  group('密码重置后本地缓存', () {
    test('令牌失效不清空离线修改；用新令牌登录后重放', () async {
      final chans = <FakeChannel>[];
      final store = MemoryStore();
      final c = SyncClient(store: store, deviceId: 'pc', maxBackoff: const Duration(milliseconds: 20), channelFactory: (_) {
        final f = FakeChannel();
        chans.add(f);
        return f;
      });
      Future<void> pump() => Future<void>.delayed(const Duration(milliseconds: 5));
      c.connect('h:1', 'old');
      await pump();
      chans.last.serverSend({'type': 'auth_error', 'message': '密码已重置，请重新登录'});
      await pump();
      expect(c.state, ConnState.authError);
      // 离线时写的内容
      final b = c.create(kind: BlockKind.message, title: '', payload: {'text': '离线写的'});
      await pump();
      expect(c.pendingCount, greaterThan(0));
      expect((store.data!['outbox'] as List), isNotEmpty);
      // 重新登录（新令牌）
      c.connect('h:1', 'new');
      await pump();
      expect(chans.last.sentOfType('auth').single['token'], 'new');
      chans.last.serverSend({'type': 'auth_ok', 'user_id': 'u1', 'username': 'bill'});
      await pump();
      chans.last.serverSend({'type': 'sync_complete', 'latest_seq': 0});
      await pump();
      expect(chans.last.sentOfType('upsert_block').map((m) => m['id']), contains(b.id));
      c.dispose();
    });
  });

  group('导出我的数据', () {
    test('zip 包含 JSON、Markdown、附件、回收站和未同步修改', () async {
      Map<String, dynamic> blk(String id, String kind, String title, Map p, {String? parent, int? del, bool purged = false}) => {
            'id': id, 'kind': kind, 'title': title, 'payload': p, 'parent_id': parent, 'viewed_mode': 'global',
            'viewed_global': false, 'created_at': 1, 'updated_at': 1, 'created_by': 'pc', 'deleted': purged,
            'deleted_at': del, 'seq': 1,
          };
      final cache = {
        'last_seq': 9,
        'blocks': [
          blk('page1', 'page', '周报', {'icon': '📝'}),
          blk('b1', 'page', '', {'type': 'todo', 'text': '写测试', 'checked': true, 'order': 1}, parent: 'page1'),
          blk('b2', 'page', '', {'type': 'bullet', 'text': '嵌套', 'order': 1}, parent: 'b1'),
          blk('f1', 'file', 'a/b.pdf', {'file_id': 'abcdef1234', 'name': 'a/b.pdf', 'order': 2}, parent: 'page1'),
          blk('f2', 'file', 'gone.txt', {'file_id': 'ffff0000', 'name': 'gone.txt'}),
          blk('t1', 'note', '旧笔记', {'markdown': '回收站内容'}, del: 5),
          blk('x', 'note', '已彻底删除', {}, purged: true),
        ],
        'outbox': [
          {'type': 'upsert_block', 'id': 'n9'}
        ],
      };
      final r = await buildLocalExport(
        cache: cache,
        username: 'bill',
        server: 'h:1',
        readAttachment: (b) async => b['id'] == 'f1' ? [1, 2, 3] : null,
      );
      expect((r.blocks, r.trashed, r.files, r.missingFiles, r.pending), (7, 1, 1, 1, 1));
      final z = ZipDecoder().decodeBytes(r.bytes);
      String read(String n) => utf8.decode(z.findFile(n)!.content as List<int>);
      expect(jsonDecode(read('manifest.json'))['source'], 'client-cache');
      expect((jsonDecode(read('blocks.json')) as List).length, 7);
      expect(jsonDecode(read('pending_outbox.json')), isNotEmpty);
      final md = read('markdown/周报.md');
      expect(md, contains('# 📝 周报'));
      expect(md, contains('- [x] 写测试'));
      expect(md, contains('  - 嵌套'));
      expect(md, contains('](../files/abcdef12-a_b.pdf)'));
      expect(z.findFile('files/abcdef12-a_b.pdf')!.content, [1, 2, 3]);
      expect(read('markdown/回收站/旧笔记.md'), contains('回收站内容'));
      expect(z.files.any((f) => f.name.contains('已彻底删除')), isFalse);
    });
  });
}
