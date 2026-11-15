// v0.4 组件行为：弹窗可用 Esc 关闭；删除可撤销；分段控件 / 开关 / 筛选标签可用。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:syncnotes/blocks/builtin_types.dart';
import 'package:syncnotes/main.dart';
import 'package:syncnotes/services/settings.dart';
import 'package:syncnotes/sync/local_store.dart';
import 'package:syncnotes/ui/ds.dart';

import 'fake_channel.dart';
import 'responsive_test.dart' show seed;

void main() {
  setUpAll(registerBuiltinTypes);

  Future<FakeChannel> pump(WidgetTester tester, {Size size = const Size(400, 900)}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({'server': 'h:1', 'token': 'tok', 'username': 'bill', 'device_id': 'dev-c'});
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
    return ch;
  }

  testWidgets('block menu sheet closes with Esc and with a tap outside', (tester) async {
    await pump(tester);
    await tester.tap(find.byKey(const Key('cardMore')).first);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('menuDelete')), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('menuDelete')), findsNothing);
    await tester.tap(find.byKey(const Key('cardMore')).first);
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(200, 20));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('menuDelete')), findsNothing);
  });

  testWidgets('deleting from the menu shows an undo snackbar that restores the item', (tester) async {
    await pump(tester);
    final before = find.byWidgetPredicate((w) => w.key == const ValueKey('card-m2'));
    expect(before, findsOneWidget);
    await tester.tap(find.descendant(of: before, matching: find.byKey(const Key('cardMore'))));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('menuDelete')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('card-m2')), findsNothing);
    expect(find.text('撤销'), findsOneWidget);
    await tester.tap(find.text('撤销'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('card-m2')), findsOneWidget);
  });

  testWidgets('undo snackbar auto-dismisses after a few seconds', (tester) async {
    await pump(tester);
    await tester.tap(find.descendant(of: find.byKey(const ValueKey('card-m2')), matching: find.byKey(const Key('cardMore'))));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('menuDelete')));
    await tester.pumpAndSettle();
    expect(find.text('撤销'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(find.text('撤销'), findsNothing);
  });

  testWidgets('filter tabs filter; create menu opens and closes with Esc', (tester) async {
    await pump(tester);
    await tester.tap(find.byKey(const Key('filter-file')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('card-f1')), findsOneWidget);
    expect(find.byKey(const ValueKey('card-m2')), findsNothing);
    await tester.tap(find.byKey(const Key('filter-all')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('quickNewButton')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('create-page')), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('create-page')), findsNothing);
  });

  testWidgets('settings switches toggle', (tester) async {
    await pump(tester);
    await tester.tap(find.byKey(const Key('homeSettings')));
    await tester.pumpAndSettle();
    final sw = find.byKey(const Key('notifySwitch'));
    final before = tester.widget<AppSwitch>(sw).value;
    await tester.tap(sw);
    await tester.pumpAndSettle();
    expect(tester.widget<AppSwitch>(sw).value, !before);
  });

  testWidgets('sidebar tree: expand / collapse shows child rows', (tester) async {
    await pump(tester, size: const Size(1280, 800));
    expect(find.byKey(const ValueKey('tree-p3')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('expand-p1')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('tree-p3')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('expand-p1')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('tree-p3')), findsNothing);
  });

  testWidgets('code block copy button copies and shows a snackbar', (tester) async {
    await pump(tester, size: const Size(1280, 1400));
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String?;
      return null;
    });
    await tester.tap(find.byKey(const ValueKey('tree-p1')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('copyCode-t4')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('copyCode-t4')));
    await tester.pumpAndSettle();
    expect(copied, contains('reallyLongVariableName'));
    expect(find.text('代码已复制'), findsOneWidget);
  });
}
