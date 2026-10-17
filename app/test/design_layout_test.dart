// v0.3 视觉回归：封面上的页面图标布局、行内 Markdown 所见即所得渲染。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:syncnotes/blocks/builtin_types.dart';
import 'package:syncnotes/main.dart';
import 'package:syncnotes/pages/inline_md.dart';
import 'package:syncnotes/services/settings.dart';
import 'package:syncnotes/ui/ds.dart';
import 'package:syncnotes/sync/local_store.dart';

import 'fake_channel.dart';

Map<String, dynamic> blk(String id, String kind, {String title = '', Map<String, dynamic>? payload, String? parent, int seq = 1}) => {
      'id': id,
      'kind': kind,
      'title': title,
      'payload': payload ?? {},
      'parent_id': parent,
      'viewed_mode': 'per_device',
      'viewed_global': false,
      'created_at': seq,
      'updated_at': seq,
      'created_by': 'other',
      'deleted': false,
      'seq': seq,
    };

void main() {
  setUpAll(registerBuiltinTypes);

  Future<void> pumpWithPage(WidgetTester tester, Size size, {bool cover = true, bool dark = false}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({
      'server': 'h:1', 'token': 'tok', 'username': 'bill', 'device_id': 'dev-v',
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
    ch.serverSend({'type': 'block_update', 'block': blk('p1', 'page', title: '路线图', payload: {'icon': '🚀', if (cover) 'cover': 'sky'}, seq: 1)});
    ch.serverSend({
      'type': 'block_update',
      'block': blk('t1', 'text', parent: 'p1', seq: 2, payload: {'type': 'paragraph', 'text': '支持 **粗体**、*斜体*、`代码` 和 [链接](https://a.b)', 'order': 1.0}),
    });
    ch.serverSend({'type': 'sync_complete', 'latest_seq': 2});
    await tester.pumpAndSettle();
    if (size.width >= 900) {
      await tester.tap(find.text('路线图').first);
    } else {
      await tester.tap(find.text('路线图').first);
    }
    await tester.pumpAndSettle();
  }

  for (final size in const [Size(1200, 860), Size(390, 800)]) {
    testWidgets('page icon overlaps the cover bottom edge, fully visible, above it (${size.width.toInt()}px)', (tester) async {
      await pumpWithPage(tester, size);
      final cover = tester.getRect(find.byKey(const Key('pageCover')));
      final icon = tester.getRect(find.byKey(const Key('pageIcon')));
      // 跨越封面下沿：上半在封面里、下半在封面外
      expect(icon.top, lessThan(cover.bottom));
      expect(icon.bottom, greaterThan(cover.bottom));
      // 覆盖比例约 30%–60%（Notion ≈ 一半）
      final ratio = (cover.bottom - icon.top) / icon.height;
      expect(ratio, inInclusiveRange(0.3, 0.6));
      // 完整可见：在屏幕内、不被裁切
      expect(icon.left, greaterThanOrEqualTo(0));
      expect(icon.right, lessThanOrEqualTo(size.width));
      // 绘制顺序：图标在封面之后（Stack 中位于更上层）
      final stack = find.ancestor(of: find.byKey(const Key('pageIconPos')), matching: find.byType(Stack)).first;
      final kids = (tester.widget<Stack>(stack)).children;
      expect(kids.last.key, const Key('pageIconPos'));
      // 标题与图标之间留有间距，不重叠
      final title = tester.getRect(find.byKey(const Key('pageTitle')));
      expect(title.top - icon.bottom, greaterThanOrEqualTo(8));
      // 图标与标题左对齐（±12px，允许 emoji 内边距）
      expect((icon.left + 6 - title.left).abs(), lessThanOrEqualTo(12));
    });
  }

  testWidgets('without cover the icon sits above the title without overlap', (tester) async {
    await pumpWithPage(tester, const Size(1200, 860), cover: false);
    expect(find.byKey(const Key('pageCover')), findsNothing);
    final icon = tester.getRect(find.byKey(const Key('pageIcon')));
    final title = tester.getRect(find.byKey(const Key('pageTitle')));
    expect(title.top, greaterThanOrEqualTo(icon.bottom));
  });

  for (final size in const [Size(1600, 1000), Size(390, 800)]) {
    testWidgets('cover sheet is a full-width (max 520) sheet (${size.width.toInt()}px)', (tester) async {
      await pumpWithPage(tester, size);
      await tester.tap(find.byKey(const Key('pageCover')));
      await tester.pumpAndSettle();
      final sheet = tester.getRect(find.descendant(of: find.byType(BottomSheet), matching: find.byType(Material)).first);
      expect(sheet.width, size.width >= 900 ? 520 : size.width);
      final picker = tester.getRect(find.byKey(const Key('coverPicker')));
      expect(picker.width, greaterThan(sheet.width - 60));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('golden: page head (cover + icon + title) layout', (tester) async {
    await pumpWithPage(tester, const Size(1200, 860));
    await expectLater(find.byKey(const Key('pageHead')), matchesGoldenFile('goldens/page_head_wide.png'));
  });

  testWidgets('covers are calm solid tones; dark mode uses the dark tone; legacy keys map', (tester) async {
    await pumpWithPage(tester, const Size(1200, 860), dark: true);
    final c = tester.widget<Container>(find.byKey(const Key('pageCover')));
    expect(c.color, coverTones['blue']!.$2); // 旧键 sky → blue
    expect(c.decoration, isNull); // 不再是渐变
    for (final k in legacyCoverMap.keys) {
      expect(coverToneKey(k), isNotNull);
    }
  });

  group('inline markdown rendering', () {
    List<TextSpan> leaves(InlineSpan s) {
      final out = <TextSpan>[];
      s.visitChildren((c) {
        if (c is TextSpan && c.text != null) out.add(c);
        return true;
      });
      return out;
    }

    Future<BuildContext> ctx(WidgetTester tester) async {
      late BuildContext c;
      await tester.pumpWidget(MaterialApp(home: Builder(builder: (b) {
        c = b;
        return const SizedBox();
      })));
      return c;
    }

    testWidgets('markers hidden when unfocused; bold/italic/code/link styled', (tester) async {
      final c = await ctx(tester);
      final ctrl = InlineMarkdownController(text: 'a **b** *斜* *it* `c` [d](https://x.y)');
      final spans = leaves(ctrl.buildTextSpan(context: c, style: const TextStyle(fontSize: 16), withComposing: false));
      for (final m in spans.where((s) => const ['**', '*', '`', '[', '](https://x.y)', ']', '(https://x.y)'].contains(s.text))) {
        expect(m.style!.fontSize, lessThan(0.1), reason: 'marker "${m.text}" must be hidden');
        expect(m.style!.color!.a, 0);
      }
      final visible = spans.where((s) => (s.style?.fontSize ?? 16) > 1).map((s) => s.text).join();
      expect(visible, isNot(contains('**')));
      expect(visible, isNot(contains('`')));
      expect(visible, isNot(contains('https://x.y')));
      final bold = spans.firstWhere((s) => s.text == 'b');
      expect(bold.style!.fontWeight, FontWeight.w700);
      // 中文斜体不用合成倾斜（会与相邻字重叠、像删除线）；西文用斜体
      final cjk = spans.firstWhere((s) => s.text == '斜');
      expect(cjk.style!.fontStyle, isNot(FontStyle.italic));
      expect(cjk.style!.decoration, isNot(TextDecoration.lineThrough));
      expect(spans.firstWhere((s) => s.text == 'it').style!.fontStyle, FontStyle.italic);
      expect(spans.firstWhere((s) => s.text == 'c').style!.fontFamily, isNotNull);
    });

    testWidgets('arithmetic asterisks are not treated as italic', (tester) async {
      final c = await ctx(tester);
      final ctrl = InlineMarkdownController(text: '2 * 3 * 4');
      final spans = leaves(ctrl.buildTextSpan(context: c, style: const TextStyle(fontSize: 16), withComposing: false));
      expect(spans.every((s) => (s.style?.fontSize ?? 16) > 1), isTrue);
    });

    testWidgets('markers revealed (faded) only around the caret when focused', (tester) async {
      final c = await ctx(tester);
      final ctrl = InlineMarkdownController(text: '**b** and **e**')
        ..reveal = true
        ..selection = const TextSelection.collapsed(offset: 2);
      final spans = leaves(ctrl.buildTextSpan(context: c, style: const TextStyle(fontSize: 16), withComposing: false));
      final markers = spans.where((s) => s.text == '**').toList();
      expect(markers, hasLength(4));
      expect(markers[0].style!.fontSize, 16); // 光标所在片段：可见但淡化
      expect(markers[0].style!.color!.a, lessThan(0.5));
      expect(markers[2].style!.fontSize, lessThan(0.1)); // 其他片段：仍隐藏
    });

    test('plainInline strips all markers for previews', () {
      expect(plainInline('支持 **粗体**、*斜体*、`代码`、~~删~~ 和 [链接](https://a.b)'), '支持 粗体、斜体、代码、删 和 链接');
      expect(plainInline('2 * 3 * 4'), '2 * 3 * 4');
      expect(plainInline('*a*'), 'a');
    });
  });
}
