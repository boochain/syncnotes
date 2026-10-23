// v0.4：同一行的元素必须同高、垂直居中；同类列表行高度一致。
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
import 'responsive_test.dart' show seed, expectClean;

void main() {
  setUpAll(registerBuiltinTypes);

  Future<FakeChannel?> pump(WidgetTester tester, Size size, {bool loggedIn = true, bool dark = false, double scale = 1.0}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = scale;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    SharedPreferences.setMockInitialValues({
      if (loggedIn) ...{'server': 'h:1', 'token': 'tok', 'username': 'bill'},
      'device_id': 'dev-a',
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
    if (!loggedIn) return null;
    final ch = chans.first;
    ch.serverSend({'type': 'auth_ok', 'user_id': 'u', 'username': 'bill'});
    await tester.pump(const Duration(milliseconds: 50));
    seed(ch);
    await tester.pumpAndSettle();
    return ch;
  }

  Rect r(WidgetTester t, Finder f) => t.getRect(f);
  void sameRow(WidgetTester t, List<Finder> fs, double h, {String why = ''}) {
    final rects = [for (final f in fs) r(t, f)];
    for (final x in rects) {
      expect(x.height, closeTo(h, 0.01), reason: '$why height');
      expect(x.center.dy, closeTo(rects.first.center.dy, 0.51), reason: '$why vertical centre');
    }
  }

  testWidgets('settings: theme selector is a 32 high segmented control at 1.0', (tester) async {
    await pump(tester, const Size(400, 760));
    await tester.tap(find.byKey(const Key('homeSettings')));
    await tester.pumpAndSettle();
    expect(r(tester, find.byKey(const Key('themeSelector'))).height, Sizes.control);
    await tester.tap(find.byKey(const Key('seg-2')));
    await tester.pumpAndSettle();
    expect(Theme.of(tester.element(find.byKey(const Key('themeSelector')))).brightness, Brightness.dark);
  });

  testWidgets('send bar: + / input / send share 36px height and centre line', (tester) async {
    await pump(tester, const Size(400, 760));
    sameRow(tester, [
      find.byKey(const Key('quickNewButton')),
      find.byKey(const Key('quickSendField')),
      find.byKey(const Key('quickSendButton')),
    ], Sizes.input, why: 'send bar');
  });

  testWidgets('inbox rows: every card (message/page/file/folder/note) is exactly 56 high', (tester) async {
    await pump(tester, const Size(400, 1400));
    final cards = find.byWidgetPredicate((w) => w.key is ValueKey<String> && (w.key as ValueKey<String>).value.startsWith('card-'));
    expect(cards, findsAtLeastNWidgets(5));
    for (final e in cards.evaluate()) {
      expect(tester.getSize(find.byWidget(e.widget)).height, Sizes.listRow, reason: '${e.widget.key}');
    }
    // 卡片内：标题与时间在同一基线行，“更多”按钮 28 并与卡片垂直居中
    // 视觉 28（按钮外观）；触屏点击区 48（TouchTarget）
    final more = r(tester, find.descendant(of: find.byKey(const Key('cardMore')).first, matching: find.byType(Material)).first);
    final card = r(tester, cards.first);
    expect(more.height, Sizes.compact);
    expect(r(tester, find.byKey(const Key('cardMore')).first).height, greaterThanOrEqualTo(48));
    expect(more.center.dy, closeTo(card.center.dy, 0.51));
  });

  testWidgets('home header: buttons 32, centred with the title in a 44 bar; filter tabs 28 centred in 44 row', (tester) async {
    await pump(tester, const Size(400, 760));
    // 视觉尺寸 32（按钮的 Material 外观）；触屏点击区扩大到 48 宽、占满 44 高的顶栏
    Finder visual(String k) => find.descendant(of: find.byKey(Key(k)), matching: find.byType(Material)).first;
    sameRow(tester, [visual('menuButton'), visual('homeSearch'), visual('homeSettings')], Sizes.control, why: 'header');
    for (final k in ['menuButton', 'homeSearch', 'homeSettings']) {
      final hit = r(tester, find.byKey(Key(k)));
      expect(hit.width, greaterThanOrEqualTo(48), reason: '$k touch target width');
      expect(hit.height, greaterThanOrEqualTo(Sizes.bar - 1), reason: '$k touch target height');
    }
    expect(r(tester, find.byKey(const Key('homeTitle'))).center.dy, closeTo(r(tester, find.byKey(const Key('homeSearch'))).center.dy, 1));
    final tabs = ['all', 'msg', 'page', 'file'].map((k) => find.byKey(Key('filter-$k'))).toList();
    sameRow(tester, tabs, Sizes.compact, why: 'filter');
    final row = r(tester, find.byKey(const Key('filterRow')));
    expect(row.height, Sizes.bar);
    expect(r(tester, tabs.first).center.dy, closeTo(row.center.dy, 0.51));
  });

  testWidgets('sidebar: nav rows and page tree rows are all 32 high; header 44', (tester) async {
    await pump(tester, const Size(1280, 800));
    expect(r(tester, find.byKey(const Key('sidebarHeader'))).height, Sizes.bar);
    final rows = [
      find.byKey(const Key('sidebarSearch')),
      find.byKey(const Key('sidebarInbox')),
      find.byKey(const Key('sidebarSettings')),
      find.byKey(const ValueKey('tree-p1')),
      find.byKey(const ValueKey('tree-p2')),
    ];
    for (final f in rows) {
      expect(r(tester, f).height, Sizes.control, reason: '$f');
    }
    // 展开子页面：子行同高、缩进 16
    await tester.tap(find.byKey(const ValueKey('expand-p1')));
    await tester.pumpAndSettle();
    expect(r(tester, find.byKey(const ValueKey('tree-p3'))).height, Sizes.control);
  });

  testWidgets('slash menu rows 44; quick switcher rows 44; block menu sheet rows 44', (tester) async {
    await pump(tester, const Size(1280, 800));
    await tester.tap(find.byKey(const ValueKey('tree-p2')));
    await tester.pumpAndSettle();
    // 空页面：点页脚新建段落，输入 /
    await tester.tap(find.byKey(const Key('pageFooter')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(EditableText).last, '/');
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('slashMenu')), findsOneWidget);
    final items = find.byWidgetPredicate((w) => w.key is ValueKey<String> && (w.key as ValueKey<String>).value.startsWith('slash-'));
    expect(items, findsAtLeastNWidgets(4));
    for (final e in items.evaluate().take(5)) {
      expect(tester.getSize(find.byWidget(e.widget)).height, closeTo(Sizes.bar, 0.01));
    }
    expectClean(tester, 'slash');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    for (final k in ['switch-0', 'switch-1']) {
      expect(r(tester, find.byKey(ValueKey(k))).height, closeTo(Sizes.bar, 0.01));
    }
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
  });

  for (final size in const [Size(320, 640), Size(390, 844), Size(1280, 800)]) {
    for (final dark in [false, true]) {
      testWidgets('settings / block menu / create menu / login fit (${size.width.toInt()} ${dark ? 'dark' : 'light'} x1.3)', (tester) async {
        await pump(tester, size, dark: dark, scale: 1.3);
        // 块菜单（底部弹窗）
        await tester.tap(find.byKey(const Key('cardMore')).first);
        await tester.pumpAndSettle();
        expectClean(tester, 'block menu');
        await tester.tapAt(const Offset(5, 5));
        await tester.pumpAndSettle();
        // 新建菜单
        await tester.tap(find.byKey(const Key('quickNewButton')));
        await tester.pumpAndSettle();
        expectClean(tester, 'create menu');
        await tester.tapAt(const Offset(5, 5));
        await tester.pumpAndSettle();
        // 设置
        if (size.width >= 900) {
          await tester.tap(find.byKey(const Key('sidebarSettings')));
        } else {
          await tester.tap(find.byKey(const Key('homeSettings')));
        }
        await tester.pumpAndSettle();
        expectClean(tester, 'settings');
        expect(find.byKey(const Key('themeSelector')), findsOneWidget);
        // 1.3 倍字号下只允许单行增高（不换行）
        expect(r(tester, find.byKey(const Key('themeSelector'))).height, lessThanOrEqualTo(Sizes.control * 1.3));
      });

      testWidgets('login fits (${size.width.toInt()} ${dark ? 'dark' : 'light'} x1.3); rows and button 44', (tester) async {
        await pump(tester, size, loggedIn: false, dark: dark, scale: 1.3);
        expectClean(tester, 'login');
        await pump(tester, size, loggedIn: false, dark: dark);
        // 视觉 44；触屏点击区 48（MaterialTapTargetSize.padded）
        expect(r(tester, find.descendant(of: find.byKey(const Key('loginButton')), matching: find.byType(Material)).first).height, Sizes.bar);
        expect(r(tester, find.byKey(const Key('loginButton'))).height, greaterThanOrEqualTo(48));
        expect(r(tester, find.byKey(const Key('userField'))).center.dy, isNotNull);
        final form = r(tester, find.byKey(const Key('loginForm')));
        expect(form.height, closeTo(4 * Sizes.bar + 3 + 2, 0.01)); // 4 行（含记住密码）+ 3 分隔线 + 上下边框
      });
    }
  }
}
