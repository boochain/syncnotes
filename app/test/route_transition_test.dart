import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syncnotes/ui/motion.dart';
import 'package:syncnotes/ui/theme.dart';

/// v0.8.2 回归：弹出页是不透明圆角卡片。卡片只要有一点可见（不透明度 > 0），
/// 背景层就必须已经把下层页面完全盖住——任何一帧都不能让下层文字和卡片内容叠在一起。
/// 进入、退出都逐帧检查（退出是同一条时间轴倒放）。
void main() {
  double fadeAbove(WidgetTester tester, Finder f) {
    final fades = find.ancestor(of: f, matching: find.byType(FadeTransition));
    var v = 1.0;
    for (final e in fades.evaluate()) {
      v *= (e.widget as FadeTransition).opacity.value;
    }
    return v;
  }

  Future<void> checkFrames(WidgetTester tester, {required int frames, required void Function() onFrame}) async {
    for (var i = 0; i < frames; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      if (find.byKey(const Key('cardSurface')).evaluate().isEmpty) break;
      onFrame();
    }
  }

  for (final size in [const Size(400, 800), const Size(1400, 900)]) {
    testWidgets('card route covers the page below before the card appears (${size.width.toInt()} wide)', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final nav = GlobalKey<NavigatorState>();
      await tester.pumpWidget(MaterialApp(
        navigatorKey: nav,
        theme: buildAppTheme(Brightness.light),
        home: const Scaffold(backgroundColor: Colors.transparent, body: Center(child: Text('ROOT'))),
      ));
      nav.currentState!.push(fadeRoute(const Scaffold(
        key: Key('pushed'),
        backgroundColor: Colors.transparent,
        body: Center(child: Text('PAGE')),
      )));
      await tester.pump();
      var sawMid = false;
      void frame() {
        final cover = fadeAbove(tester, find.byKey(const Key('cardBackdrop')));
        final card = fadeAbove(tester, find.byKey(const Key('cardSurface')));
        if (card > 0) {
          expect(cover, greaterThanOrEqualTo(0.999), reason: 'card visible ($card) while page below still shows through (cover $cover)');
        }
        if (card > 0.2 && card < 0.8) sawMid = true;
      }

      await checkFrames(tester, frames: 40, onFrame: frame);
      expect(sawMid, isTrue, reason: 'card should fade in, not pop');
      await tester.pumpAndSettle();

      // 卡片四周留边距（露出背景），带圆角
      final rect = tester.getRect(find.byKey(const Key('cardSurface')));
      expect(rect.left, greaterThanOrEqualTo(8));
      expect(rect.top, greaterThanOrEqualTo(8));
      expect(size.width - rect.right, greaterThanOrEqualTo(8));
      expect(size.height - rect.bottom, greaterThanOrEqualTo(8));
      final deco = tester.widget<DecoratedBox>(find.byKey(const Key('cardSurface'))).decoration as BoxDecoration;
      expect((deco.color!).a, 1.0, reason: 'card surface must be fully opaque');
      expect(deco.borderRadius, isNotNull);

      nav.currentState!.pop();
      await tester.pump();
      sawMid = false;
      await checkFrames(tester, frames: 40, onFrame: frame);
      expect(sawMid, isTrue, reason: 'pop must play a symmetric exit');
      await tester.pumpAndSettle();
      expect(find.text('ROOT'), findsOneWidget);
    });
  }

  testWidgets('dialogs cover the page below with the background only', (tester) async {
    final nav = GlobalKey<NavigatorState>();
    final obs = PopupCoverObserver();
    await tester.pumpWidget(MaterialApp(
      navigatorKey: nav,
      navigatorObservers: [obs],
      theme: buildAppTheme(Brightness.light),
      home: const Scaffold(body: Center(child: Text('ROOT'))),
    ));
    showDialog<void>(context: nav.currentContext!, builder: (_) => const AlertDialog(content: Text('DIALOG')));
    await tester.pumpAndSettle();
    final cover = tester.widget<Opacity>(find.byKey(const Key('popupCover')));
    expect(cover.opacity, 1.0);
    nav.currentState!.pop();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('popupCover')), findsNothing);
  });

  test('page routes share the themed transition', () {
    expect(fadeRoute<void>(const SizedBox()), isA<MaterialPageRoute<void>>());
  });
}
