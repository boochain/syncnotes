import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syncnotes/ui/motion.dart';
import 'package:syncnotes/ui/theme.dart';

/// v0.8.1 回归：透明（液态玻璃）页面推入时，下层主页必须被新页的左边缘裁掉，
/// 任何一帧都不能在同一位置同时画出两层字；返回动画同理（进出对称）。
void main() {
  RenderClipRect leadingClipOf(WidgetTester tester, Finder text) {
    RenderObject? r = tester.renderObject(text);
    while (r != null) {
      if (r is RenderClipRect && r.clipper != null) return r;
      r = r.parent;
    }
    throw StateError('no leading clip above $text');
  }

  Future<void> expectNoOverlap(WidgetTester tester) async {
    final clip = leadingClipOf(tester, find.text('ROOT'));
    final rect = clip.clipper!.getClip(clip.size);
    final rootRight = clip.localToGlobal(Offset(rect.width, 0)).dx;
    final pageLeft = tester.getTopLeft(find.byKey(const Key('pushed'))).dx;
    expect(rootRight, lessThanOrEqualTo(pageLeft + 1.0), reason: 'root painted under the incoming page');
  }

  testWidgets('pushed page occludes the page below during push and pop', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
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
    var sawPartial = false;
    for (var i = 0; i < 24; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      if (find.text('ROOT').evaluate().isEmpty) break;
      final left = tester.getTopLeft(find.byKey(const Key('pushed'))).dx;
      if (left > 1 && left < 399) sawPartial = true;
      await expectNoOverlap(tester);
    }
    expect(sawPartial, isTrue, reason: 'incoming page should slide in');
    await tester.pumpAndSettle();

    nav.currentState!.pop();
    await tester.pump();
    var sawExit = false;
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      if (find.byKey(const Key('pushed')).evaluate().isEmpty) break;
      final left = tester.getTopLeft(find.byKey(const Key('pushed'))).dx;
      if (left > 1 && left < 399) sawExit = true;
      await expectNoOverlap(tester);
    }
    expect(sawExit, isTrue, reason: 'pop must play a symmetric exit');
    await tester.pumpAndSettle();
    expect(find.text('ROOT'), findsOneWidget);
  });

  test('page routes share the themed transition (root receives secondaryAnimation)', () {
    final r = fadeRoute<void>(const SizedBox());
    expect(r, isA<MaterialPageRoute<void>>());
    expect(MaterialPageRoute<void>(builder: (_) => const SizedBox()).canTransitionTo(r as TransitionRoute), isTrue);
  });
}
