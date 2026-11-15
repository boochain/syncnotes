import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:syncnotes/platform/notifications.dart';
import 'package:syncnotes/services/settings.dart';

void main() {
  Future<BuildContext> host(WidgetTester tester) async {
    late BuildContext ctx;
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (c) {
      ctx = c;
      return const SizedBox();
    })));
    return ctx;
  }

  testWidgets('explains why before requesting; asks only once', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final s = await Settings.load();
    final ctx = await host(tester);
    var requested = 0;
    final f = askNotificationPermission(ctx, s, isEnabled: () async => false, request: () async {
      requested++;
      return true;
    });
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('notifRationale')), findsOneWidget);
    expect(requested, 0); // 先说明，未直接弹系统权限框
    await tester.tap(find.text('开启'));
    await tester.pumpAndSettle();
    await f;
    expect(requested, 1);

    await askNotificationPermission(ctx, s, isEnabled: () async => false, request: () async => true);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('notifRationale')), findsNothing);
  });

  testWidgets('"以后再说" does not request; already-enabled shows nothing', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final s = await Settings.load();
    final ctx = await host(tester);
    await askNotificationPermission(ctx, s, isEnabled: () async => true, request: () async => fail('no'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('notifRationale')), findsNothing);
    var requested = 0;
    final f = askNotificationPermission(ctx, s, isEnabled: () async => false, request: () async {
      requested++;
      return true;
    });
    await tester.pumpAndSettle();
    await tester.tap(find.text('以后再说'));
    await tester.pumpAndSettle();
    await f;
    expect(requested, 0);
  });
}
