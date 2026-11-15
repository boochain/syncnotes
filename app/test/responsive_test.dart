// 响应式：在所有目标尺寸 × 浅/深色 × 1.0/1.3 字号（代表尺寸另测 2.0）下打开关键界面，断言没有任何 RenderFlex 溢出。
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:syncnotes/blocks/builtin_types.dart';
import 'package:syncnotes/main.dart';
import 'package:syncnotes/services/settings.dart';
import 'package:syncnotes/sync/local_store.dart';

import 'fake_channel.dart';

const longCjk = '这是一个非常非常长的中文页面标题，用来测试在窄屏手机上标题是否会溢出或者被裁切掉的情况';
const longEn = 'An extremely long English page title that keeps going to check ellipsis and wrapping behaviour';
const longUrl = 'https://example.com/a/very/long/path/that/does/not/contain/any/spaces/at/all/and/keeps/going?query=1234567890abcdef';

const sizes = <Size>[
  Size(320, 640), Size(360, 740), Size(390, 844), Size(430, 932), // 手机竖屏
  Size(400, 640), // 托盘小窗
  Size(844, 390), Size(740, 360), // 手机横屏
  Size(600, 900), Size(800, 700), Size(1024, 768), Size(1280, 800), Size(1600, 1000), Size(1920, 1080),
];

Map<String, dynamic> blk(String id, String kind, String title, Map<String, dynamic> p, int seq, {String? parent}) => {
      'id': id, 'kind': kind, 'title': title, 'payload': p, 'parent_id': parent,
      'viewed_mode': 'per_device', 'viewed_global': false, 'created_at': seq,
      'updated_at': seq, 'created_by': 'other', 'deleted': false, 'seq': seq
    };

void seed(FakeChannel ch) {
  var s = 0;
  void send(String id, String kind, String title, Map<String, dynamic> p, {String? parent}) =>
      ch.serverSend({'type': 'block_update', 'block': blk(id, kind, title, p, ++s, parent: parent)});
  send('p1', 'page', longCjk, {'icon': '📒', 'order': 1000, 'cover': 'blue'});
  send('t1', 'text', '', {'type': 'paragraph', 'text': '$longEn $longUrl', 'order': 1}, parent: 'p1');
  send('t2', 'text', '', {'type': 'heading1', 'text': longCjk, 'order': 2}, parent: 'p1');
  send('t3', 'text', '', {'type': 'callout', 'text': longUrl, 'icon': '💡', 'order': 3}, parent: 'p1');
  send('t4', 'text', '', {'type': 'code', 'text': 'final reallyLongVariableName = someFunction(argumentOne, argumentTwo, argumentThree);', 'order': 4}, parent: 'p1');
  send('t5', 'text', '', {'type': 'todo', 'text': longCjk, 'checked': true, 'order': 5}, parent: 'p1');
  send('t6', 'text', '', {'type': 'bulleted', 'text': longEn, 'order': 6}, parent: 'p1');
  send('t7', 'text', '', {'type': 'quote', 'text': longCjk, 'order': 7}, parent: 'p1');
  send('p2', 'page', longEn, {'icon': '🚀', 'order': 2000});
  send('p3', 'page', '子页面 $longCjk', {'icon': '📄', 'order': 1}, parent: 'p1');
  send('m1', 'message', longUrl, {'text': '$longUrl\n$longCjk'});
  send('m2', 'message', '短消息', {'text': '短消息'});
  send('n1', 'note', longEn, {'markdown': '# $longEn\n$longCjk'});
  send('f1', 'file', 'a_very_long_file_name_without_spaces_${'x' * 40}.tar.gz', {'name': 'a_very_long_file_name_without_spaces_${'x' * 40}.tar.gz', 'size': 123456789});
  send('d1', 'folder', '$longCjk 文件夹', {});
  send('m3', 'message', '文件夹里', {'text': '文件夹里'}, parent: 'd1');
  ch.serverSend({'type': 'sync_complete', 'latest_seq': s});
}

/// 找出所有正在溢出的 RenderFlex，打印创建者，便于定位
void expectClean(WidgetTester tester, String where) {
  final bad = <String>[];
  for (final r in tester.allRenderObjects.whereType<RenderFlex>()) {
    if (r.toStringShort().contains('OVERFLOWING')) bad.add('${r.debugCreator}');
  }
  final ex = tester.takeException();
  expect(bad, isEmpty, reason: '$where: overflowing flex: ${bad.join('\n')}');
  expect(ex, isNull, reason: '$where: $ex');
}

void main() {
  setUpAll(registerBuiltinTypes);

  // 200% 字号（Android 系统最大字号）：手机、托盘小窗、横屏、桌面各取代表尺寸
  const bigSizes = [Size(320, 640), Size(360, 740), Size(400, 640), Size(844, 390), Size(1280, 800)];
  for (final size in sizes) {
    for (final dark in [false, true]) {
      for (final scale in [1.0, 1.3, if (!dark && bigSizes.contains(size)) 2.0]) {
        final name = '${size.width.toInt()}x${size.height.toInt()} ${dark ? 'dark' : 'light'} x$scale';
        testWidgets('no overflow: $name', (tester) async {
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1;
          tester.platformDispatcher.textScaleFactorTestValue = scale;
          addTearDown(tester.view.reset);
          addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
          SharedPreferences.setMockInitialValues({
            'server': 'h:1', 'token': 'tok', 'username': 'bill_with_a_long_username_${'y' * 20}', 'device_id': 'dev-r',
            'theme_mode': dark ? 'dark' : 'light',
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
          seed(ch);
          await tester.pumpAndSettle();
          expectClean(tester, 'inbox');

          // 筛到“页面”，再打开长标题页面（横屏时列表很矮）
          await tester.tap(find.byKey(const Key('filter-page')));
          await tester.pumpAndSettle();
          expectClean(tester, 'filter');
          await tester.ensureVisible(find.byKey(const Key('card-p1')));
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const Key('card-p1')));
          await tester.pumpAndSettle();
          expectClean(tester, 'page');

          // 快速查找
          await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
          await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
          await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
          await tester.pumpAndSettle();
          expectClean(tester, 'switcher');
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          await tester.pumpAndSettle();
          expectClean(tester, 'after switcher');
        });
      }
    }
  }

  for (final size in const [Size(320, 640), Size(400, 640)]) {
    testWidgets('no overflow at 200%: settings + login ${size.width.toInt()}', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2.0;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      SharedPreferences.setMockInitialValues({'server': 'h:1', 'token': 'tok', 'username': 'bill', 'device_id': 'dev-r'});
      final settings = await Settings.load();
      await tester.pumpWidget(SyncNotesApp(settings: settings, store: MemoryStore(), channelFactory: (_) => FakeChannel()));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('homeSettings')));
      await tester.pumpAndSettle();
      expectClean(tester, 'settings');
      for (var i = 0; i < 6; i++) {
        await tester.drag(find.byType(Scrollable).last, const Offset(0, -400));
        await tester.pumpAndSettle();
        expectClean(tester, 'settings scrolled');
      }
      await tester.pumpWidget(const SizedBox());
      SharedPreferences.setMockInitialValues({'device_id': 'dev-r'});
      final s2 = await Settings.load();
      await tester.pumpWidget(SyncNotesApp(settings: s2, store: MemoryStore(), channelFactory: (_) => FakeChannel()));
      await tester.pumpAndSettle();
      expectClean(tester, 'login');
    });
  }
}
