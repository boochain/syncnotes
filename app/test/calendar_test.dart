import 'package:flutter_test/flutter_test.dart';
import 'package:syncnotes/blocks/builtin_types.dart';
import 'package:syncnotes/calendar/calendar_item.dart';
import 'package:syncnotes/calendar/calendar_reminders.dart';
import 'package:syncnotes/models/block.dart';
import 'package:syncnotes/sync/local_store.dart';
import 'package:syncnotes/sync/sync_client.dart';

void main() {
  setUpAll(registerBuiltinTypes);

  group('CivilDate', () {
    test('parses and rejects invalid dates', () {
      expect(CivilDate.tryParse('2026-11-28'), const CivilDate(2026, 11, 28));
      expect(
        CivilDate.tryParse('2026-11-28T18:00:00+08:00'),
        const CivilDate(2026, 11, 28),
      );
      expect(CivilDate.tryParse('2026-02-29'), isNull);
      expect(CivilDate.tryParse('2024-02-29'), const CivilDate(2024, 2, 29));
      expect(CivilDate.tryParse('2026-13-01'), isNull);
      expect(CivilDate.tryParse(''), isNull);
    });

    test('month-end and leap year arithmetic', () {
      expect(
        const CivilDate(2026, 1, 31).addMonths(1),
        const CivilDate(2026, 2, 28),
      );
      expect(
        const CivilDate(2024, 1, 31).addMonths(1),
        const CivilDate(2024, 2, 29),
      );
      expect(
        const CivilDate(2024, 2, 29).addYears(1),
        const CivilDate(2025, 2, 28),
      );
      expect(
        const CivilDate(2026, 11, 28).addMonths(2),
        const CivilDate(2027, 1, 28),
      );
      expect(
        const CivilDate(2026, 3, 31).addMonths(-1),
        const CivilDate(2026, 2, 28),
      );
      expect(
        const CivilDate(2026, 11, 28).addDays(3),
        const CivilDate(2026, 12, 1),
      );
    });

    test('ISO week starts on Monday', () {
      // 2026-11-28 is Saturday
      expect(
        startOfIsoWeek(const CivilDate(2026, 11, 28)),
        const CivilDate(2026, 11, 23),
      );
      expect(const CivilDate(2026, 11, 23).weekday, 1);
    });
  });

  group('billing', () {
    CalendarItem sub({
      required CivilDate start,
      CivilDate? end,
      BillingCycle cycle = BillingCycle.monthly,
      bool autoRenew = true,
      SubscriptionStatus status = SubscriptionStatus.active,
      double? amount = 18,
      String currency = 'CNY',
      CivilDate? trialEnds,
      CivilDate? lastPaid,
      int interval = 1,
      IntervalUnit unit = IntervalUnit.month,
    }) => CalendarItem(
      id: 's',
      title: '网飞',
      role: CalendarRole.subscription,
      startDate: start,
      endDate: end,
      billing: Billing(
        cycle: cycle,
        autoRenew: autoRenew,
        amount: amount,
        currency: currency,
        status: status,
        trialEnds: trialEnds,
        lastPaid: lastPaid,
        interval: interval,
        intervalUnit: unit,
      ),
    );

    test('next billing for monthly auto-renew, including month end', () {
      final it = sub(start: const CivilDate(2026, 1, 31));
      expect(
        nextBillingDate(it, const CivilDate(2026, 1, 31)),
        const CivilDate(2026, 1, 31),
      );
      expect(
        nextBillingDate(it, const CivilDate(2026, 2, 1)),
        const CivilDate(2026, 2, 28),
      );
      expect(
        nextBillingDate(it, const CivilDate(2026, 3, 1)),
        const CivilDate(2026, 3, 31),
      );
    });

    test('quarterly and yearly and custom cycles', () {
      final q = sub(
        start: const CivilDate(2026, 1, 15),
        cycle: BillingCycle.quarterly,
      );
      expect(
        nextBillingDate(q, const CivilDate(2026, 4, 1)),
        const CivilDate(2026, 4, 15),
      );
      final y = sub(
        start: const CivilDate(2025, 11, 28),
        cycle: BillingCycle.yearly,
      );
      expect(
        nextBillingDate(y, const CivilDate(2026, 11, 28)),
        const CivilDate(2026, 11, 28),
      );
      final c = sub(
        start: const CivilDate(2026, 11, 1),
        cycle: BillingCycle.custom,
        interval: 2,
        unit: IntervalUnit.week,
      );
      expect(
        nextBillingDate(c, const CivilDate(2026, 11, 20)),
        const CivilDate(2026, 11, 29),
      );
    });

    test('one-shot and non-renewing become pending after the period', () {
      final once = sub(
        start: const CivilDate(2026, 1, 1),
        cycle: BillingCycle.once,
        autoRenew: false,
        end: const CivilDate(2026, 1, 31),
      );
      expect(
        nextBillingDate(once, const CivilDate(2026, 1, 1)),
        const CivilDate(2026, 1, 1),
      );
      expect(nextBillingDate(once, const CivilDate(2026, 2, 1)), isNull);
      expect(
        resolvedStatus(once, const CivilDate(2026, 2, 1)),
        SubscriptionStatus.pending,
      );

      final month = sub(start: const CivilDate(2026, 10, 1), autoRenew: false);
      // 默认结束为下一计费日前一天 10-31
      expect(
        resolvedStatus(month, const CivilDate(2026, 10, 15)),
        SubscriptionStatus.active,
      );
      expect(
        resolvedStatus(month, const CivilDate(2026, 11, 1)),
        SubscriptionStatus.pending,
      );
      expect(nextBillingDate(month, const CivilDate(2026, 11, 1)), isNull);
    });

    test(
      'paused cancelled expired have no next billing; trial uses trial end',
      () {
        final paused = sub(
          start: const CivilDate(2026, 1, 1),
          status: SubscriptionStatus.paused,
        );
        expect(nextBillingDate(paused, const CivilDate(2026, 11, 1)), isNull);
        final trial = sub(
          start: const CivilDate(2026, 11, 1),
          trialEnds: const CivilDate(2026, 11, 14),
          status: SubscriptionStatus.trial,
        );
        expect(
          nextBillingDate(trial, const CivilDate(2026, 11, 10)),
          const CivilDate(2026, 11, 14),
        );
        expect(
          resolvedStatus(trial, const CivilDate(2026, 11, 10)),
          SubscriptionStatus.trial,
        );
        expect(
          resolvedStatus(trial, const CivilDate(2026, 11, 15)),
          SubscriptionStatus.active,
        );
      },
    );

    test('auto-renew stops after end date', () {
      final it = sub(
        start: const CivilDate(2026, 1, 1),
        end: const CivilDate(2026, 6, 1),
      );
      expect(
        nextBillingDate(it, const CivilDate(2026, 5, 1)),
        const CivilDate(2026, 5, 1),
      );
      expect(nextBillingDate(it, const CivilDate(2026, 6, 2)), isNull);
      expect(
        resolvedStatus(it, const CivilDate(2026, 6, 2)),
        SubscriptionStatus.expired,
      );
    });

    test('spend totals group by currency and ignore paused', () {
      final today = const CivilDate(2026, 11, 28);
      final items = [
        sub(start: const CivilDate(2026, 11, 1), amount: 18),
        sub(
          start: const CivilDate(2026, 1, 1),
          amount: 120,
          cycle: BillingCycle.yearly,
          currency: 'CNY',
        ),
        sub(start: const CivilDate(2026, 11, 1), amount: 10, currency: 'USD'),
        sub(
          start: const CivilDate(2026, 11, 1),
          amount: 99,
          status: SubscriptionStatus.paused,
        ),
        sub(
          start: const CivilDate(2026, 10, 30),
          amount: 20,
        ), // next billing 11-30, still this month
      ];
      items[0] = items[0].copyWith(id: 'a', title: 'A');
      items[1] = items[1].copyWith(id: 'b', title: 'B');
      items[2] = items[2].copyWith(id: 'c', title: 'C');
      items[3] = items[3].copyWith(id: 'd', title: 'D');
      items[4] = items[4].copyWith(id: 'e', title: 'E');
      final s = buildSpendSummary(items, today);
      expect(s.activeCount, 4);
      expect(s.monthlyEquivalent['CNY']!, closeTo(18 + 10 + 20, 0.01));
      expect(s.monthlyEquivalent['USD'], 10);
      expect(s.dueThisMonth['CNY'], 20);
      expect(s.dueThisMonth.containsKey('USD'), isFalse);
    });
  });

  group('countdown and important dates', () {
    test('phrases and yearly anniversary including leap day', () {
      const today = CivilDate(2026, 11, 28);
      expect(countdownPhrase(today, today), '就是今天');
      expect(countdownPhrase(today, const CivilDate(2026, 12, 5)), '还有 7 天');
      expect(countdownPhrase(today, const CivilDate(2026, 11, 20)), '已经 8 天');
      expect(
        nextAnniversary(
          const CivilDate(2000, 2, 29),
          const CivilDate(2026, 3, 1),
        ),
        const CivilDate(2027, 2, 28),
      );
      expect(nextAnniversary(const CivilDate(2000, 11, 28), today), today);
      expect(ageOn(const CivilDate(2000, 11, 28), today), 26);
      expect(ageOn(const CivilDate(2000, 11, 29), today), 25);
    });

    test('headline with age on a yearly birthday', () {
      final it = CalendarItem(
        title: '妈妈生日',
        role: CalendarRole.countdown,
        startDate: const CivilDate(1970, 12, 5),
        count: const CountSpec(repeatYearly: true, showAge: true),
      );
      expect(
        countdownHeadline(it, const CivilDate(2026, 11, 28)),
        '56 岁 · 还有 7 天',
      );
      expect(
        countdownHeadline(it, const CivilDate(2026, 12, 5)),
        '56 岁 · 就是今天',
      );
    });
  });

  group('payload and kindRaw', () {
    test('round-trips and keeps unknown fields', () {
      final it = CalendarItem(
        title: 'iCloud+',
        role: CalendarRole.subscription,
        startDate: const CivilDate(2026, 1, 15),
        notes: '家庭共享',
        color: 'teal',
        category: '云服务',
        reminders: const [1, 3],
        billing: const Billing(
          cycle: BillingCycle.yearly,
          autoRenew: true,
          amount: 168,
          currency: 'CNY',
        ),
        extra: const {'vendor_id': 'icloud', 'future_flag': true},
      );
      final p = it.toPayload();
      expect(p['vendor_id'], 'icloud');
      expect(p['future_flag'], true);
      expect(p['billing']['cycle'], 'yearly');
      final back = CalendarItem.fromPayload(it.title, p);
      expect(back.billing!.amount, 168);
      expect(back.extra['vendor_id'], 'icloud');
      expect(back.toPayload()['vendor_id'], 'icloud');
    });

    test('unknown kind strings survive upsert and cache', () {
      final b = Block.fromServer({
        'id': 't1',
        'kind': 'task',
        'title': '写报告',
        'payload': {'start_date': '2026-12-01', 'due_date': '2026-12-03'},
        'created_at': 1,
        'updated_at': 1,
      });
      expect(b.kind, BlockKind.unknown);
      expect(b.kindRaw, 'task');
      expect(b.wireKind, 'task');
      expect(b.toJson()['kind'], 'task');
      expect(b.toUpsertMessage()['kind'], 'task');
      final cal = Block.fromServer({
        'id': 'c1',
        'kind': 'calendar',
        'title': '续费',
        'payload': {'role': 'subscription', 'start_date': '2026-11-01'},
        'created_at': 1,
        'updated_at': 1,
      });
      expect(cal.kind, BlockKind.calendar);
      expect(cal.wireKind, 'calendar');
    });

    test('task blocks overlay onto the calendar without being edited', () {
      final cal = Block(
        id: 'c',
        kind: BlockKind.calendar,
        title: '体检',
        createdAt: 1,
        updatedAt: 1,
        payload: CalendarItem(
          title: '体检',
          role: CalendarRole.important,
          startDate: const CivilDate(2026, 12, 2),
          pinned: true,
        ).toPayload(),
      );
      final task = Block.fromServer({
        'id': 't',
        'kind': 'task',
        'title': '交稿',
        'payload': {'due_date': '2026-12-02'},
        'created_at': 1,
        'updated_at': 1,
      });
      final idx = CalendarIndex.fromBlocks([cal, task]);
      final day = idx.onDay(const CivilDate(2026, 12, 2));
      expect(day.map((o) => o.source), containsAll(['calendar', 'task']));
      expect(day.where((o) => o.source == 'task').single.title, '交稿');
      expect(day.where((o) => o.pinned).single.title, '体检');
    });
  });

  group('occurrences and reminders', () {
    test('expands auto-renew billing days in a window', () {
      final it = CalendarItem(
        id: 'n',
        title: '网飞',
        role: CalendarRole.subscription,
        startDate: const CivilDate(2026, 1, 5),
        billing: const Billing(
          cycle: BillingCycle.monthly,
          autoRenew: true,
          amount: 18,
        ),
      );
      final occ = expandItem(
        it,
        const CivilDate(2026, 11, 1),
        const CivilDate(2026, 12, 31),
      );
      expect(
        occ.map((o) => o.date),
        containsAll([
          const CivilDate(2026, 11, 5),
          const CivilDate(2026, 12, 5),
        ]),
      );
    });

    test('reminder offsets for all-day countdown', () {
      final it = CalendarItem(
        id: 'd',
        title: '出发',
        role: CalendarRole.countdown,
        startDate: const CivilDate(2026, 12, 5),
        reminders: const [0, 1, 7],
      );
      final now = DateTime(2026, 11, 28, 10, 0);
      final r = reminderSchedule(it, now: now);
      expect(
        r
            .map((e) => (e.offsetDays, e.when.month, e.when.day, e.when.hour))
            .toList(),
        [
          (7, 11, 28, 9), // 刚过点，仍保留给回到前台时补发
          (1, 12, 4, 9),
          (0, 12, 5, 9),
        ],
      );
    });

    test('paused subscription does not schedule reminders', () {
      final it = CalendarItem(
        id: 'p',
        title: '暂停',
        role: CalendarRole.subscription,
        startDate: const CivilDate(2026, 12, 1),
        reminders: const [0, 1],
        billing: const Billing(status: SubscriptionStatus.paused, amount: 10),
      );
      expect(reminderSchedule(it, now: DateTime(2026, 11, 28)), isEmpty);
    });
  });

  group('SyncClient integration', () {
    test(
      'calendar items stay out of the inbox, go to trash, and keep kind',
      () {
        final c = SyncClient(store: MemoryStore(), deviceId: 'pc');
        final b = c.create(
          kind: BlockKind.calendar,
          title: '网飞',
          payload: CalendarItem(
            title: '网飞',
            role: CalendarRole.subscription,
            startDate: const CivilDate(2026, 11, 1),
            billing: const Billing(amount: 18, autoRenew: true),
          ).toPayload(),
          viewedMode: ViewedMode.global,
        );
        expect(b.wireKind, 'calendar');
        expect(c.blocks, isNotEmpty);
        expect(SyncClient.isInboxItem(b), isFalse);
        expect(c.childrenOf(null).map((x) => x.id), isNot(contains(b.id)));
        expect(c.unreadCount, 0);
        expect(c.outbox.single['kind'], 'calendar');
        c.delete(b.id);
        expect(c.trash.single.id, b.id);
        expect(c.restoreAll([b.id]), isEmpty);
        expect(c.byId(b.id)!.wireKind, 'calendar');
        expect(CalendarIndex.fromBlocks(c.blocks).items.single.title, '网飞');
      },
    );

    test('trashed calendar items are not indexed', () {
      final c = SyncClient(store: MemoryStore(), deviceId: 'pc');
      final b = c.create(
        kind: BlockKind.calendar,
        title: '旧日',
        payload: CalendarItem(
          title: '旧日',
          role: CalendarRole.countdown,
          startDate: const CivilDate(2026, 12, 1),
        ).toPayload(),
      );
      c.delete(b.id);
      expect(CalendarIndex.fromBlocks(c.blocks).items, isEmpty);
      expect(CalendarIndex.fromBlocks([c.byId(b.id)!]).items, isEmpty);
    });

    test('reminder planner fires due items once', () async {
      CalendarReminders.forget();
      final c = SyncClient(store: MemoryStore(), deviceId: 'pc');
      c.create(
        kind: BlockKind.calendar,
        title: '出发',
        payload: CalendarItem(
          id: 'ignored',
          title: '出发',
          role: CalendarRole.countdown,
          startDate: const CivilDate(2026, 11, 28),
          reminders: const [0],
        ).toPayload(),
      );
      // fromBlock uses the created id
      final shown = <String>[];
      final n = await CalendarReminders.sync(
        c,
        now: DateTime(2026, 11, 28, 9, 5),
        show: (r) async => shown.add(r.title),
      );
      expect(n, 1);
      expect(shown, ['出发']);
      final n2 = await CalendarReminders.sync(
        c,
        now: DateTime(2026, 11, 28, 9, 6),
        show: (r) async => shown.add(r.title),
      );
      expect(n2, 0);
      CalendarReminders.forget();
    });
  });
}
