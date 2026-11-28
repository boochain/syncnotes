import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syncnotes/platform/desktop.dart';
import 'package:syncnotes/ui/glass.dart';
import 'package:syncnotes/ui/motion.dart';
import 'package:syncnotes/ui/theme.dart';
import 'package:syncnotes/ui/tokens.dart';

void main() {
  testWidgets('page switch fades the old view out before the new one fades in', (tester) async {
    final page = ValueNotifier(0);
    await tester.pumpWidget(MaterialApp(
      home: ValueListenableBuilder<int>(
        valueListenable: page,
        builder: (_, v, _) => MotionSwitch(child: Text('$v', key: ValueKey(v))),
      ),
    ));
    expect(find.text('0'), findsOneWidget);
    page.value = 1;
    double op(String t) => tester
        .widgetList<Opacity>(find.ancestor(of: find.text(t), matching: find.byType(Opacity)))
        .fold(1.0, (a, o) => a * o.opacity);
    // 每一帧：两层不能同时可见（不叠字），旧层有退出动画（不是瞬间消失）。
    var sawOldFading = false;
    for (var ms = 0; ms <= 300; ms += 16) {
      await tester.pump(const Duration(milliseconds: 16));
      final a = find.text('0').evaluate().isEmpty ? 0.0 : op('0');
      final b = op('1');
      if (a > 0 && a < 1) sawOldFading = true;
      expect(a > 0.01 && b > 0.01, isFalse, reason: 't=${ms}ms old=$a new=$b');
    }
    expect(sawOldFading, isTrue);
    await tester.pumpAndSettle();
    expect(find.text('0'), findsNothing);
    expect(op('1'), 1.0);
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

  test('expand and collapse never restore the same window size', () {
    const wide = Size(1120, 740);
    expect(
      DesktopShell.sizeForToggle(expand: false, current: wide, saved: wide),
      DesktopShell.windowSize,
    );
    expect(
      DesktopShell.sizeForToggle(expand: true, current: DesktopShell.windowSize, saved: DesktopShell.windowSize),
      DesktopShell.expandedSize,
    );
    expect(
      DesktopShell.sizeForToggle(expand: false, current: wide, saved: const Size(420, 640)).width,
      420,
    );
  });

  test('library thickness stays off at phone scale so the page is not drawn twice', () {
    expect(Glass.refractsAt(1), isTrue);
    expect(Glass.refractsAt(2), isTrue);
    expect(Glass.refractsAt(2.5), isFalse);
    expect(Glass.refractsAt(3.5), isFalse);
  });

  test('refraction slider still has visible strength at phone scale', () {
    expect(Glass.refractionStrength(1.00, 'standard'), 0);
    expect(Glass.refractionStrength(1.06, 'standard'), closeTo(0.5, 0.0001));
    expect(Glass.refractionStrength(1.12, 'standard'), 1);
    expect(Glass.refractionStrength(1.06, 'premium'), greaterThan(Glass.refractionStrength(1.06, 'standard')));
    expect(Glass.refractionStrength(1.12, 'minimal'), lessThan(Glass.refractionStrength(1.12, 'standard')));
  });

  test('quality tier changes fluid repaint cost', () {
    final prev = Glass.quality.value;
    addTearDown(() => Glass.quality.value = prev);
    Glass.quality.value = 'standard';
    expect(Glass.fluidPhaseStep(), closeTo(1 / (30 * 26), 0.0001));
    expect(Glass.quantizeFluidPhase(0.0101), closeTo(Glass.quantizeFluidPhase(0.0102), 0.0001));
    Glass.quality.value = 'premium';
    expect(Glass.fluidPhaseStep(), closeTo(1 / (60 * 26), 0.0001));
    Glass.quality.value = 'minimal';
    expect(Glass.fluidPhaseStep(), 1);
    expect(Glass.quantizeFluidPhase(0.4), 0);
  });

  test('page routes use the documented motion tokens', () {
    expect(Motion.medium4, const Duration(milliseconds: 400));
    expect(Motion.medium2, const Duration(milliseconds: 300));
    expect(MotionCurves.enter, MotionCurves.emphasizedDecelerate);
    expect(MotionCurves.exit, MotionCurves.emphasizedAccelerate);
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
