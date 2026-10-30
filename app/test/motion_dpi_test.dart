import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syncnotes/platform/desktop.dart';
import 'package:syncnotes/ui/glass.dart';
import 'package:syncnotes/ui/motion.dart';
import 'package:syncnotes/ui/theme.dart';

void main() {
  testWidgets('page switch drops the previous surface', (tester) async {
    final page = ValueNotifier(0);
    await tester.pumpWidget(MaterialApp(
      home: ValueListenableBuilder<int>(
        valueListenable: page,
        builder: (_, v, _) => MotionSwitch(child: Text('$v', key: ValueKey(v))),
      ),
    ));
    expect(find.text('0'), findsOneWidget);
    page.value = 1;
    await tester.pump();
    expect(find.text('0'), findsNothing);
    expect(find.text('1'), findsOneWidget);
    await tester.pumpAndSettle();
  });

  test('glass theme keeps the page opaque', () {
    for (final b in Brightness.values) {
      final base = buildAppTheme(b);
      final g = glassTheme(base, true);
      expect(g.scaffoldBackgroundColor.a, 1);
      expect(g.scaffoldBackgroundColor, base.scaffoldBackgroundColor);
      expect(g.appBarTheme.backgroundColor!.a, 1);
    }
  });

  test('page transitions are an opaque fade on every platform', () {
    for (final b in Brightness.values) {
      final theme = buildAppTheme(b);
      for (final platform in TargetPlatform.values) {
        expect(theme.pageTransitionsTheme.builders[platform], isA<OpaqueFadeTransitionsBuilder>());
      }
    }
  });

  test('refraction is off at phone scale so the page is not drawn twice', () {
    expect(Glass.refractsAt(1), isTrue);
    expect(Glass.refractsAt(2), isTrue);
    expect(Glass.refractsAt(2.5), isFalse);
    expect(Glass.refractsAt(3.5), isFalse);
  });

  testWidgets('high dpi still frosts the glass instead of a flat fill', (tester) async {
    final wasShader = Glass.useShader;
    final wasOn = Glass.enabled.value;
    Glass.useShader = false;
    Glass.enabled.value = true;
    addTearDown(() {
      Glass.useShader = wasShader;
      Glass.enabled.value = wasOn;
    });
    await tester.pumpWidget(MaterialApp(
      home: MediaQuery(
        data: const MediaQueryData(devicePixelRatio: 3.5),
        child: const Glass(child: Text('glass')),
      ),
    ));
    expect(find.byType(BackdropFilter), findsOneWidget);
    expect(find.text('glass'), findsOneWidget);
  });

  test('high dpi window is converted from physical pixels once', () {
    // 3840×2160 at 200%. Dividing twice would shrink 1120×740.
    expect(
      DesktopShell.fitWithin(const Size(1120, 740), physical: const Size(3840, 2160), devicePixelRatio: 2),
      const Size(1120, 740),
    );
    // 1920×1080 at 150%: height must stay inside the logical screen.
    final laptop = DesktopShell.fitWithin(const Size(1120, 740), physical: const Size(1920, 1080), devicePixelRatio: 1.5);
    expect(laptop.width, 1120);
    expect(laptop.height, 1080 / 1.5 - 80);
    // 1216×2640 at 3.5x: logical width is ~347, so the window keeps the minimum rather than collapsing.
    final phone = DesktopShell.fitWithin(const Size(400, 640), physical: const Size(1216, 2640), devicePixelRatio: 3.5);
    expect(phone.width, DesktopShell.minimumSize.width);
    expect(phone.height, 640);
  });
}
