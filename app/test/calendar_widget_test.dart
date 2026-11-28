import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:syncnotes/app_scope.dart';
import 'package:syncnotes/blocks/builtin_types.dart';
import 'package:syncnotes/calendar/calendar_item.dart';
import 'package:syncnotes/calendar/lunar.dart';
import 'package:syncnotes/main.dart';
import 'package:syncnotes/models/block.dart';
import 'package:syncnotes/services/auth_api.dart';
import 'package:syncnotes/services/settings.dart';
import 'package:syncnotes/sync/local_store.dart';
import 'package:syncnotes/sync/sync_client.dart';
import 'package:syncnotes/ui/calendar_page.dart';
import 'package:syncnotes/ui/theme.dart';

import 'fake_channel.dart';

void main() {
  setUpAll(registerBuiltinTypes);

  group('农历显示', () {
    test('已知春节与中秋对照', () {
      expect(solarToLunar(DateTime(2026, 2, 17))?.label, '正月初一');
      expect(solarToLunar(DateTime(2025, 1, 29))?.label, '正月初一');
      expect(solarToLunar(DateTime(2024, 2, 10))?.label, '正月初一');
      expect(solarToLunar(DateTime(2020, 1, 25))?.label, '正月初一');
      expect(solarToLunar(DateTime(2026, 9, 25))?.label, '八月十五');
      expect(solarToLunar(DateTime(2024, 9, 17))?.label, '八月十五');
      expect(solarToLunar(DateTime(2025, 10, 6))?.label, '八月十五');
      final spring = lunarToSolar(2026, 1, 1);
      expect(spring, DateTime(2026, 2, 17));
    });
  });

  group('日历界面', () {
    Future<SyncClient> pumpPage(
      WidgetTester tester, {
      Size size = const Size(400, 800),
    }) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({'device_id': 'pc'});
      final settings = await Settings.load();
      final sync = SyncClient(store: MemoryStore(), deviceId: 'pc');
      await tester.pumpWidget(
        AppScope(
          services: AppServices(
            sync: sync,
            settings: settings,
            api: AuthApi(),
            logout: () async {},
          ),
          child: MaterialApp(
            locale: const Locale('zh', 'CN'),
            theme: buildAppTheme(Brightness.light),
            home: const CalendarPage(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return sync;
    }

    testWidgets('月历显示今天，并从新建入口保存订阅', (tester) async {
      final today = CivilDate.today();
      final sync = await pumpPage(tester);
      expect(find.byKey(const Key('calendarPage')), findsOneWidget);
      expect(find.byKey(Key('calendarDay-${today.ymd}')), findsOneWidget);

      await tester.tap(find.byKey(const Key('calendarAdd')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('calendarNew-subscription')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('calendarEditor')), findsOneWidget);

      await tester.enterText(find.byKey(const Key('calendarTitle')), '网飞');
      await tester.enterText(find.byKey(const Key('calendarAmount')), '18');
      await tester.tap(find.byKey(const Key('calendarSave')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('calendarEditor')), findsNothing);
      expect(
        sync.blocks.where((b) => b.kind == BlockKind.calendar),
        hasLength(1),
      );
      final item = CalendarItem.fromBlock(sync.blocks.single);
      expect(item.title, '网飞');
      expect(item.role, CalendarRole.subscription);
      expect(item.billing?.amount, 18);

      // 订阅看板能看到
      await tester.tap(find.byKey(const Key('calendarMenu')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('订阅'));
      await tester.pumpAndSettle();
      expect(find.text('网飞'), findsWidgets);
      expect(find.textContaining('每月折合'), findsOneWidget);
    });

    testWidgets('倒数日卡片显示剩余天数，返回键先离开编辑页', (tester) async {
      final sync = await pumpPage(tester);
      final target = CivilDate.today().addDays(10);
      sync.create(
        kind: BlockKind.calendar,
        title: '出发',
        payload: CalendarItem(
          title: '出发',
          role: CalendarRole.countdown,
          startDate: target,
        ).toPayload(),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('calendarMenu')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('倒数'));
      await tester.pumpAndSettle();
      expect(find.text('出发'), findsOneWidget);
      expect(find.text('10'), findsWidgets);

      await tester.tap(
        find.byKey(Key('calendarCount-${sync.blocks.single.id}')),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('calendarEditor')), findsOneWidget);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('calendarEditor')), findsNothing);
      expect(find.byKey(const Key('calendarPage')), findsOneWidget);
    });

    testWidgets('矮屏月历六周都可见且格子不溢出', (tester) async {
      final sync = await pumpPage(tester, size: const Size(360, 640));
      final today = CivilDate.today();
      sync.create(
        kind: BlockKind.calendar,
        title: '网飞',
        payload: CalendarItem(
          title: '网飞',
          role: CalendarRole.subscription,
          startDate: today,
          billing: const Billing(cycle: BillingCycle.monthly, amount: 18),
        ).toPayload(),
      );
      sync.create(
        kind: BlockKind.calendar,
        title: '出发',
        payload: CalendarItem(
          title: '出发',
          role: CalendarRole.countdown,
          startDate: today.addDays(10),
        ).toPayload(),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      final last = startOfIsoWeek(startOfMonth(today)).addDays(41);
      final finder = find.byKey(Key('calendarDay-${last.ymd}'));
      expect(finder, findsOneWidget);
      final rect = tester.getRect(finder);
      expect(rect.height, greaterThan(16));
      expect(rect.bottom, lessThanOrEqualTo(640.5));
    });
  });

  group('侧边栏入口与系统返回', () {
    Future<void> pumpApp(
      WidgetTester tester, {
      Size size = const Size(400, 800),
    }) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({
        'server': 'h:1',
        'token': 'tok',
        'username': 'bill',
        'device_id': 'dev-c',
      });
      final settings = await Settings.load();
      await tester.pumpWidget(
        SyncNotesApp(
          settings: settings,
          store: MemoryStore(),
          channelFactory: (_) => FakeChannel(),
        ),
      );
      await tester.pumpAndSettle();
    }

    Future<void> back(WidgetTester tester) async {
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
    }

    testWidgets('窄屏从菜单打开日历，返回回到收件箱且不会退出', (tester) async {
      await pumpApp(tester);
      await tester.tap(find.byKey(const Key('menuButton')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('sidebarCalendar')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('calendarPage')), findsOneWidget);

      await back(tester);
      expect(find.byKey(const Key('calendarPage')), findsNothing);
      expect(find.byKey(const Key('homeTitle')), findsOneWidget);
    });

    testWidgets('宽屏侧边栏打开日历后 Ctrl+W 关闭', (tester) async {
      await pumpApp(tester, size: const Size(1200, 800));
      await tester.tap(find.byKey(const Key('sidebarCalendar')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('calendarPage')), findsOneWidget);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyW);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('calendarPage')), findsNothing);
    });
  });
}
