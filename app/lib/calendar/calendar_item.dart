/// 日历条目模型、周期推算与日程展开。
///
/// 块类型为 `calendar`，载荷字段见 docs/calendar.md。
/// 未识别的载荷键会原样保留，避免以后加字段时被旧客户端丢掉。
library;

import '../models/block.dart';

/// 不含时刻的公历日期，用来存全天事件，避免时区把“那天”移到前一天。
class CivilDate implements Comparable<CivilDate> {
  final int year, month, day;
  const CivilDate(this.year, this.month, this.day);

  factory CivilDate.fromDateTime(DateTime d) =>
      CivilDate(d.year, d.month, d.day);

  factory CivilDate.today([DateTime? now]) =>
      CivilDate.fromDateTime(now ?? DateTime.now());

  /// 接受 `YYYY-MM-DD`，或 ISO 日期时间的前 10 位。
  static CivilDate? tryParse(Object? v) {
    if (v == null) return null;
    final raw = v.toString().trim();
    if (raw.isEmpty) return null;
    final s = raw.length >= 10 ? raw.substring(0, 10) : raw;
    final p = s.split('-');
    if (p.length != 3) return null;
    final y = int.tryParse(p[0]);
    final m = int.tryParse(p[1]);
    final d = int.tryParse(p[2]);
    if (y == null ||
        m == null ||
        d == null ||
        m < 1 ||
        m > 12 ||
        d < 1 ||
        d > 31) {
      return null;
    }
    final last = DateTime(y, m + 1, 0).day;
    if (d > last) return null;
    return CivilDate(y, m, d);
  }

  /// 本地午夜，只用于日期算术，不当成时刻。
  DateTime get dateTime => DateTime(year, month, day);

  String get ymd {
    final ys = year.abs().toString().padLeft(4, '0');
    final ms = month.toString().padLeft(2, '0');
    final ds = day.toString().padLeft(2, '0');
    return year < 0 ? '-$ys-$ms-$ds' : '$ys-$ms-$ds';
  }

  /// 1 = 周一 … 7 = 周日（与 [DateTime.weekday] 相同）。
  int get weekday => dateTime.weekday;

  CivilDate addDays(int n) =>
      CivilDate.fromDateTime(dateTime.add(Duration(days: n)));

  /// 按日历月加减；没有那一天时落到该月最后一天（1 月 31 日 + 1 个月 = 2 月 28/29 日）。
  CivilDate addMonths(int n) {
    final total = year * 12 + (month - 1) + n;
    final y = total ~/ 12;
    final m = total % 12 + 1;
    final last = DateTime(y, m + 1, 0).day;
    return CivilDate(y, m, day < last ? day : last);
  }

  CivilDate addYears(int n) => addMonths(n * 12);

  int differenceInDays(CivilDate other) =>
      other.dateTime.difference(dateTime).inDays;

  bool isBefore(CivilDate o) => compareTo(o) < 0;
  bool isAfter(CivilDate o) => compareTo(o) > 0;
  bool isSameOrBefore(CivilDate o) => compareTo(o) <= 0;
  bool isSameOrAfter(CivilDate o) => compareTo(o) >= 0;

  @override
  int compareTo(CivilDate o) {
    if (year != o.year) return year.compareTo(o.year);
    if (month != o.month) return month.compareTo(o.month);
    return day.compareTo(o.day);
  }

  @override
  bool operator ==(Object other) =>
      other is CivilDate && other.year == year && other.month == month && other.day == day;

  @override
  int get hashCode => Object.hash(year, month, day);

  @override
  String toString() => ymd;
}

CivilDate dateOnYear(CivilDate base, int year) {
  final last = DateTime(year, base.month + 1, 0).day;
  return CivilDate(year, base.month, base.day < last ? base.day : last);
}

/// 本周一（ISO 周，从周一开始）。
CivilDate startOfIsoWeek(CivilDate d) => d.addDays(1 - d.weekday);

CivilDate startOfMonth(CivilDate d) => CivilDate(d.year, d.month, 1);

CivilDate endOfMonth(CivilDate d) =>
    CivilDate(d.year, d.month, DateTime(d.year, d.month + 1, 0).day);

enum CalendarRole { event, subscription, important, countdown }

enum BillingCycle { weekly, monthly, quarterly, yearly, custom, once }

enum IntervalUnit { day, week, month, year }

enum SubscriptionStatus { active, trial, paused, cancelled, expired, pending }

enum RecurFreq { none, daily, weekly, monthly, yearly }

enum CountMode { both, countdown, countup }

class Recurrence {
  final RecurFreq freq;
  final int interval;
  final CivilDate? until;
  const Recurrence({this.freq = RecurFreq.none, this.interval = 1, this.until});

  bool get isRecurring => freq != RecurFreq.none && interval > 0;

  Map<String, dynamic> toJson() => {
    'freq': freq.name,
    'interval': interval,
    if (until != null) 'until': until!.ymd,
  };

  factory Recurrence.fromJson(Object? v) {
    if (v is! Map) return const Recurrence();
    final m = Map<String, dynamic>.from(v);
    return Recurrence(
      freq: _enumFrom(RecurFreq.values, m['freq'], RecurFreq.none),
      interval: _positiveInt(m['interval'], 1),
      until: CivilDate.tryParse(m['until']),
    );
  }
}

class Billing {
  final BillingCycle cycle;
  final int interval;
  final IntervalUnit intervalUnit;
  final bool autoRenew;
  final double? amount;
  final String currency;
  final SubscriptionStatus status;
  final CivilDate? trialEnds;
  final CivilDate? lastPaid;
  final String url;

  const Billing({
    this.cycle = BillingCycle.monthly,
    this.interval = 1,
    this.intervalUnit = IntervalUnit.month,
    this.autoRenew = true,
    this.amount,
    this.currency = 'CNY',
    this.status = SubscriptionStatus.active,
    this.trialEnds,
    this.lastPaid,
    this.url = '',
  });

  Map<String, dynamic> toJson() => {
    'cycle': cycle.name,
    'interval': interval,
    'interval_unit': intervalUnit.name,
    'auto_renew': autoRenew,
    if (amount != null) 'amount': amount,
    'currency': currency,
    'status': status.name,
    if (trialEnds != null) 'trial_ends': trialEnds!.ymd,
    if (lastPaid != null) 'last_paid': lastPaid!.ymd,
    if (url.isNotEmpty) 'url': url,
  };

  factory Billing.fromJson(Object? v) {
    if (v is! Map) return const Billing();
    final m = Map<String, dynamic>.from(v);
    return Billing(
      cycle: _enumFrom(BillingCycle.values, m['cycle'], BillingCycle.monthly),
      interval: _positiveInt(m['interval'], 1),
      intervalUnit: _enumFrom(
        IntervalUnit.values,
        m['interval_unit'],
        IntervalUnit.month,
      ),
      autoRenew: m['auto_renew'] != false,
      amount: _asDouble(m['amount']),
      currency: (m['currency'] as String?)?.trim().isNotEmpty == true
          ? (m['currency'] as String).trim().toUpperCase()
          : 'CNY',
      status: _enumFrom(
        SubscriptionStatus.values,
        m['status'],
        SubscriptionStatus.active,
      ),
      trialEnds: CivilDate.tryParse(m['trial_ends']),
      lastPaid: CivilDate.tryParse(m['last_paid']),
      url: (m['url'] ?? '').toString(),
    );
  }

  /// 从起始日起算第 [periods] 个计费日（0 即起始日）。
  /// 必须始终锚定起始日，避免 1 月 31 日逐月累加后永远停在 28 日。
  CivilDate advanceN(CivilDate start, int periods) {
    if (periods <= 0 || cycle == BillingCycle.once) return start;
    final n = (interval < 1 ? 1 : interval) * periods;
    return switch (cycle) {
      BillingCycle.weekly => start.addDays(7 * n),
      BillingCycle.monthly => start.addMonths(n),
      BillingCycle.quarterly => start.addMonths(3 * n),
      BillingCycle.yearly => start.addYears(n),
      BillingCycle.once => start,
      BillingCycle.custom => switch (intervalUnit) {
        IntervalUnit.day => start.addDays(n),
        IntervalUnit.week => start.addDays(7 * n),
        IntervalUnit.month => start.addMonths(n),
        IntervalUnit.year => start.addYears(n),
      },
    };
  }

  /// 按本条订阅的周期往前推一个计费日（仍锚定 [from] 的日，只走一期）。
  CivilDate advance(CivilDate from) => advanceN(from, 1);

  /// 折算到“每个月平均多少钱”，一次性订阅为 0。
  double monthlyEquivalent() {
    final a = amount;
    if (a == null || a == 0) return 0;
    final n = interval < 1 ? 1 : interval;
    return switch (cycle) {
      BillingCycle.monthly => a / n,
      BillingCycle.quarterly => a / (3 * n),
      BillingCycle.yearly => a / (12 * n),
      BillingCycle.weekly => a * 52 / 12 / n,
      BillingCycle.once => 0,
      BillingCycle.custom => switch (intervalUnit) {
        IntervalUnit.day => a * 365.25 / 12 / n,
        IntervalUnit.week => a * 52 / 12 / n,
        IntervalUnit.month => a / n,
        IntervalUnit.year => a / 12 / n,
      },
    };
  }

  String get cycleLabel {
    final n = interval < 1 ? 1 : interval;
    return switch (cycle) {
      BillingCycle.weekly => n == 1 ? '每周' : '每 $n 周',
      BillingCycle.monthly => n == 1 ? '单月' : '每 $n 个月',
      BillingCycle.quarterly => n == 1 ? '单季度' : '每 $n 个季度',
      BillingCycle.yearly => n == 1 ? '单年' : '每 $n 年',
      BillingCycle.once => '一次性',
      BillingCycle.custom => switch (intervalUnit) {
        IntervalUnit.day => n == 1 ? '每天' : '每 $n 天',
        IntervalUnit.week => n == 1 ? '每周' : '每 $n 周',
        IntervalUnit.month => n == 1 ? '单月' : '每 $n 个月',
        IntervalUnit.year => n == 1 ? '单年' : '每 $n 年',
      },
    };
  }
}

class CountSpec {
  final CountMode mode;
  final bool repeatYearly;
  final bool showAge;
  const CountSpec({
    this.mode = CountMode.both,
    this.repeatYearly = false,
    this.showAge = false,
  });

  Map<String, dynamic> toJson() => {
    'mode': mode.name,
    'repeat_yearly': repeatYearly,
    'show_age': showAge,
  };

  factory CountSpec.fromJson(Object? v) {
    if (v is! Map) return const CountSpec();
    final m = Map<String, dynamic>.from(v);
    return CountSpec(
      mode: _enumFrom(CountMode.values, m['mode'], CountMode.both),
      repeatYearly: m['repeat_yearly'] == true,
      showAge: m['show_age'] == true,
    );
  }
}

/// 一条日历记录（对应一个 `kind=calendar` 的块）。
class CalendarItem {
  final String? id;
  final String title;
  final CalendarRole role;
  final bool allDay;
  final CivilDate startDate;
  final CivilDate? endDate;
  final String? startTime;
  final String? endTime;
  final String timezone;
  final String notes;
  final String color;
  final bool pinned;
  final String category;

  /// 提前提醒的天数，0 表示当天。
  final List<int> reminders;
  final Recurrence recur;
  final Billing? billing;
  final CountSpec count;
  final Map<String, dynamic> extra;

  const CalendarItem({
    this.id,
    required this.title,
    required this.role,
    required this.startDate,
    this.allDay = true,
    this.endDate,
    this.startTime,
    this.endTime,
    this.timezone = 'Asia/Shanghai',
    this.notes = '',
    this.color = '',
    this.pinned = false,
    this.category = '',
    this.reminders = const [0, 1, 7],
    this.recur = const Recurrence(),
    this.billing,
    this.count = const CountSpec(),
    this.extra = const {},
  });

  CivilDate get effectiveEnd => endDate ?? startDate;

  bool get isPinned => pinned || role == CalendarRole.important;

  String get displayColor => color.isNotEmpty ? color : defaultColorFor(role);

  static String defaultColorFor(CalendarRole r) => switch (r) {
    CalendarRole.event => 'blue',
    CalendarRole.subscription => 'orange',
    CalendarRole.important => 'red',
    CalendarRole.countdown => 'purple',
  };

  static const knownKeys = {
    'schema',
    'role',
    'all_day',
    'start_date',
    'end_date',
    'start_time',
    'end_time',
    'timezone',
    'notes',
    'color',
    'pinned',
    'category',
    'reminders',
    'recur',
    'billing',
    'count',
  };

  factory CalendarItem.fromBlock(Block b) =>
      CalendarItem.fromPayload(b.title, b.payload, id: b.id);

  factory CalendarItem.fromPayload(
    String title,
    Map<String, dynamic> payload, {
    String? id,
    CivilDate? fallbackStart,
  }) {
    final extra = <String, dynamic>{};
    for (final e in payload.entries) {
      if (!knownKeys.contains(e.key)) extra[e.key] = e.value;
    }
    final start =
        CivilDate.tryParse(payload['start_date']) ??
        fallbackStart ??
        CivilDate.today();
    var end = CivilDate.tryParse(payload['end_date']);
    if (end != null && end.isBefore(start)) end = start;
    final remindersRaw = payload['reminders'];
    final reminders = <int>[];
    if (remindersRaw is List) {
      for (final v in remindersRaw) {
        final n = v is int ? v : int.tryParse(v.toString());
        if (n != null && n >= 0 && n <= 365 && !reminders.contains(n)) {
          reminders.add(n);
        }
      }
      reminders.sort();
    }
    final startTime = _asTime(payload['start_time']);
    return CalendarItem(
      id: id,
      title: title,
      role: _enumFrom(CalendarRole.values, payload['role'], CalendarRole.event),
      allDay: payload['all_day'] != false && startTime == null,
      startDate: start,
      endDate: end,
      startTime: startTime,
      endTime: _asTime(payload['end_time']),
      timezone: (payload['timezone'] as String?)?.trim().isNotEmpty == true
          ? (payload['timezone'] as String).trim()
          : 'Asia/Shanghai',
      notes: (payload['notes'] ?? '').toString(),
      color: (payload['color'] ?? '').toString(),
      pinned: payload['pinned'] == true,
      category: (payload['category'] ?? '').toString(),
      reminders: reminders.isEmpty && payload['reminders'] == null
          ? const [0, 1, 7]
          : reminders,
      recur: Recurrence.fromJson(payload['recur']),
      billing: payload['billing'] is Map
          ? Billing.fromJson(payload['billing'])
          : null,
      count: CountSpec.fromJson(payload['count']),
      extra: extra,
    );
  }

  Map<String, dynamic> toPayload() {
    return <String, dynamic>{
      ...extra,
      'schema': 1,
      'role': role.name,
      'all_day': allDay,
      'start_date': startDate.ymd,
      if (endDate != null) 'end_date': endDate!.ymd,
      if (!allDay && startTime != null) 'start_time': startTime,
      if (!allDay && endTime != null) 'end_time': endTime,
      'timezone': timezone,
      if (notes.isNotEmpty) 'notes': notes,
      if (color.isNotEmpty) 'color': color,
      if (pinned) 'pinned': true,
      if (category.isNotEmpty) 'category': category,
      'reminders': reminders,
      if (recur.isRecurring) 'recur': recur.toJson(),
      if (billing != null) 'billing': billing!.toJson(),
      if (role == CalendarRole.countdown || role == CalendarRole.important)
        'count': count.toJson(),
    };
  }

  CalendarItem copyWith({
    String? id,
    String? title,
    CalendarRole? role,
    bool? allDay,
    CivilDate? startDate,
    CivilDate? endDate,
    bool clearEnd = false,
    String? startTime,
    String? endTime,
    String? timezone,
    String? notes,
    String? color,
    bool? pinned,
    String? category,
    List<int>? reminders,
    Recurrence? recur,
    Billing? billing,
    bool clearBilling = false,
    CountSpec? count,
    Map<String, dynamic>? extra,
  }) => CalendarItem(
    id: id ?? this.id,
    title: title ?? this.title,
    role: role ?? this.role,
    allDay: allDay ?? this.allDay,
    startDate: startDate ?? this.startDate,
    endDate: clearEnd ? null : (endDate ?? this.endDate),
    startTime: startTime ?? this.startTime,
    endTime: endTime ?? this.endTime,
    timezone: timezone ?? this.timezone,
    notes: notes ?? this.notes,
    color: color ?? this.color,
    pinned: pinned ?? this.pinned,
    category: category ?? this.category,
    reminders: reminders ?? this.reminders,
    recur: recur ?? this.recur,
    billing: clearBilling ? null : (billing ?? this.billing),
    count: count ?? this.count,
    extra: extra ?? this.extra,
  );
}

/// 日历格子上的一次出现（一条订阅的某次扣款、一个周年纪念日等）。
class CalOccurrence {
  final String blockId;
  final String title;
  final CivilDate date;
  final CivilDate endDate;
  final bool allDay;
  final String? startTime;
  final String? endTime;
  final String source; // calendar | task
  final CalendarRole? role;
  final String color;
  final bool pinned;
  final String? subtitle;
  final CalendarItem? item;

  const CalOccurrence({
    required this.blockId,
    required this.title,
    required this.date,
    CivilDate? endDate,
    this.allDay = true,
    this.startTime,
    this.endTime,
    this.source = 'calendar',
    this.role,
    this.color = 'blue',
    this.pinned = false,
    this.subtitle,
    this.item,
  }) : endDate = endDate ?? date;

  bool covers(CivilDate d) => !d.isBefore(date) && !d.isAfter(endDate);
}

/// [base] 在 [onOrAfter] 当天或之后的下一个周年（闰年 2 月 29 日在平年落到 2 月 28 日）。
CivilDate nextAnniversary(CivilDate base, CivilDate onOrAfter) {
  var c = dateOnYear(base, onOrAfter.year);
  if (c.isBefore(onOrAfter)) c = dateOnYear(base, onOrAfter.year + 1);
  return c;
}

CivilDate lastAnniversary(CivilDate base, CivilDate onOrBefore) {
  final next = nextAnniversary(base, onOrBefore);
  if (next == onOrBefore) return next;
  var prev = dateOnYear(base, next.year - 1);
  return prev.isBefore(base) ? base : prev;
}

int ageOn(CivilDate birth, CivilDate on) {
  var age = on.year - birth.year;
  if (on.month < birth.month || (on.month == birth.month && on.day < birth.day)) {
    age--;
  }
  return age < 0 ? 0 : age;
}

/// 今天相对目标日的文案。
String countdownPhrase(
  CivilDate today,
  CivilDate target, {
  CountMode mode = CountMode.both,
}) {
  final days = today.differenceInDays(target);
  if (days == 0) return '就是今天';
  if (days > 0) {
    if (mode == CountMode.countup) return '已经 0 天';
    return '还有 $days 天';
  }
  if (mode == CountMode.countdown) return '已过 ${-days} 天';
  return '已经 ${-days} 天';
}

bool _isYearlyCount(CalendarItem item) =>
    item.count.repeatYearly || item.recur.freq == RecurFreq.yearly;

String countdownHeadline(CalendarItem item, CivilDate today) {
  final yearly = _isYearlyCount(item);
  late final CivilDate target;
  if (!yearly) {
    target = item.startDate;
  } else if (item.count.mode == CountMode.countup &&
      item.startDate.isBefore(today) &&
      nextAnniversary(item.startDate, today) != today) {
    target = lastAnniversary(item.startDate, today);
  } else {
    target = nextAnniversary(item.startDate, today);
  }
  final phrase = countdownPhrase(today, target, mode: item.count.mode);
  if (!item.count.showAge) return phrase;
  if (yearly) {
    final coming = nextAnniversary(item.startDate, today);
    final comingAge = ageOn(item.startDate, coming);
    if (coming == today) return '$comingAge 岁 · 就是今天';
    if (item.count.mode == CountMode.countup && target != coming) {
      return '${ageOn(item.startDate, target)} 岁 · $phrase';
    }
    return '$comingAge 岁 · $phrase';
  }
  return '${ageOn(item.startDate, today)} 岁 · $phrase';
}

/// 解析出的状态：尊重用户设定，并对到期 / 试用做一次推算。
SubscriptionStatus resolvedStatus(CalendarItem item, CivilDate today) {
  final b = item.billing;
  if (b == null) return SubscriptionStatus.active;
  if (b.status == SubscriptionStatus.paused ||
      b.status == SubscriptionStatus.cancelled ||
      b.status == SubscriptionStatus.expired) {
    return b.status;
  }
  if (b.trialEnds != null && !today.isAfter(b.trialEnds!)) {
    return SubscriptionStatus.trial;
  }
  final end = item.endDate;
  if (end != null && today.isAfter(end)) {
    return b.autoRenew
        ? SubscriptionStatus.expired
        : SubscriptionStatus.pending;
  }
  if (!b.autoRenew && b.cycle != BillingCycle.once) {
    final periodEnd = item.endDate ?? b.advance(item.startDate).addDays(-1);
    if (today.isAfter(periodEnd)) return SubscriptionStatus.pending;
  }
  return b.status == SubscriptionStatus.trial
      ? SubscriptionStatus.active
      : b.status;
}

String statusLabel(SubscriptionStatus s) => switch (s) {
  SubscriptionStatus.active => '使用中',
  SubscriptionStatus.trial => '试用中',
  SubscriptionStatus.paused => '已暂停',
  SubscriptionStatus.cancelled => '已取消',
  SubscriptionStatus.expired => '已到期',
  SubscriptionStatus.pending => '待续',
};

String roleLabel(CalendarRole r) => switch (r) {
  CalendarRole.event => '日程',
  CalendarRole.subscription => '订阅',
  CalendarRole.important => '重要日',
  CalendarRole.countdown => '倒数日',
};

/// 下次扣款日。暂停 / 取消 / 到期没有下次扣款。试用未结束时返回试用结束日（首次扣款）。
CivilDate? nextBillingDate(CalendarItem item, CivilDate today) {
  final b = item.billing;
  if (b == null) return null;
  final st = resolvedStatus(item, today);
  if (st == SubscriptionStatus.paused ||
      st == SubscriptionStatus.cancelled ||
      st == SubscriptionStatus.expired) {
    return null;
  }
  if (b.trialEnds != null && !today.isAfter(b.trialEnds!)) return b.trialEnds;
  if (b.cycle == BillingCycle.once || !b.autoRenew) {
    if (!item.startDate.isBefore(today)) return item.startDate;
    return null;
  }
  if (item.endDate != null && today.isAfter(item.endDate!)) return null;
  var n = 0;
  CivilDate cursor = item.startDate;
  while (n < 20000) {
    cursor = b.advanceN(item.startDate, n);
    final paid = b.lastPaid;
    final afterPaid = paid == null || cursor.isAfter(paid);
    if (!cursor.isBefore(today) && afterPaid) break;
    n++;
    if (b.cycle == BillingCycle.once) return null;
  }
  if (item.endDate != null && cursor.isAfter(item.endDate!)) return null;
  return cursor;
}

/// 把条目在 [from, to] 闭区间内展开为格子上的出现。
List<CalOccurrence> expandItem(
  CalendarItem item,
  CivilDate from,
  CivilDate to, {
  CivilDate? today,
}) {
  final out = <CalOccurrence>[];
  void addOcc(CivilDate start, CivilDate end, {String? subtitle}) {
    if (end.isBefore(from) || start.isAfter(to)) return;
    out.add(
      CalOccurrence(
        blockId: item.id ?? '',
        title: item.title,
        date: start,
        endDate: end,
        allDay: item.allDay,
        startTime: item.startTime,
        endTime: item.endTime,
        role: item.role,
        color: item.displayColor,
        pinned: item.isPinned,
        subtitle: subtitle,
        item: item,
      ),
    );
  }

  if (item.role == CalendarRole.subscription) {
    final t = today ?? CivilDate.today();
    final b = item.billing;
    if (!item.startDate.isAfter(to) && !item.startDate.isBefore(from)) {
      addOcc(item.startDate, item.startDate, subtitle: '订阅开始');
    }
    if (item.endDate != null &&
        !item.endDate!.isAfter(to) &&
        !item.endDate!.isBefore(from)) {
      addOcc(item.endDate!, item.endDate!, subtitle: '订阅结束');
    }
    if (b != null && b.autoRenew && b.cycle != BillingCycle.once) {
      var n = 0;
      while (n < 20000) {
        final cursor = b.advanceN(item.startDate, n);
        if (cursor.isAfter(to)) break;
        if (item.endDate != null && cursor.isAfter(item.endDate!)) break;
        if (!cursor.isBefore(from)) {
          addOcc(
            cursor,
            cursor,
            subtitle: cursor == item.startDate ? '首单' : '续费',
          );
        }
        n++;
      }
    } else if (b != null && !b.autoRenew) {
      final next = nextBillingDate(item, t);
      if (next != null && !next.isBefore(from) && !next.isAfter(to)) {
        addOcc(next, next, subtitle: '待扣款');
      }
    }
    if (b?.trialEnds != null &&
        !b!.trialEnds!.isBefore(from) &&
        !b.trialEnds!.isAfter(to)) {
      addOcc(b.trialEnds!, b.trialEnds!, subtitle: '试用结束');
    }
    return _dedupeOcc(out);
  }

  if ((item.role == CalendarRole.countdown ||
          item.role == CalendarRole.important) &&
      _isYearlyCount(item)) {
    final t = today ?? CivilDate.today();
    for (var y = from.year - 1; y <= to.year + 1; y++) {
      final d = dateOnYear(item.startDate, y);
      if (!d.isBefore(item.startDate) && !d.isBefore(from) && !d.isAfter(to)) {
        addOcc(d, d, subtitle: countdownPhrase(t, d, mode: item.count.mode));
      }
    }
    return out;
  }

  if (item.recur.isRecurring) {
    var cursor = item.startDate;
    final until = item.recur.until;
    var guard = 0;
    if (cursor.isBefore(from)) {
      while (_advanceRecur(cursor, item.recur).isSameOrBefore(from) &&
          guard++ < 20000) {
        final n = _advanceRecur(cursor, item.recur);
        if (!n.isAfter(cursor)) break;
        cursor = n;
      }
    }
    guard = 0;
    final span = item.effectiveEnd.differenceInDays(item.startDate);
    while (!cursor.isAfter(to) && guard++ < 20000) {
      if (until != null && cursor.isAfter(until)) break;
      final end = span > 0 ? cursor.addDays(span) : cursor;
      if (!end.isBefore(from)) addOcc(cursor, end);
      final n = _advanceRecur(cursor, item.recur);
      if (!n.isAfter(cursor)) break;
      cursor = n;
    }
    return out;
  }

  addOcc(item.startDate, item.effectiveEnd);
  return out;
}

CivilDate _advanceRecur(CivilDate from, Recurrence r) {
  final n = r.interval < 1 ? 1 : r.interval;
  return switch (r.freq) {
    RecurFreq.none => from,
    RecurFreq.daily => from.addDays(n),
    RecurFreq.weekly => from.addDays(7 * n),
    RecurFreq.monthly => from.addMonths(n),
    RecurFreq.yearly => from.addYears(n),
  };
}

List<CalOccurrence> _dedupeOcc(List<CalOccurrence> list) {
  final seen = <String>{};
  final out = <CalOccurrence>[];
  for (final o in list) {
    final k = '${o.blockId}@${o.date.ymd}@${o.subtitle}';
    if (seen.add(k)) out.add(o);
  }
  return out;
}

class SpendSummary {
  final Map<String, double> monthlyEquivalent;
  final Map<String, double> yearlyEquivalent;
  final Map<String, double> dueThisMonth;
  final int activeCount;
  final List<(CalendarItem, CivilDate)> upcomingRenewals;
  final List<(CalendarItem, String)> upcomingCountdowns;

  const SpendSummary({
    this.monthlyEquivalent = const {},
    this.yearlyEquivalent = const {},
    this.dueThisMonth = const {},
    this.activeCount = 0,
    this.upcomingRenewals = const [],
    this.upcomingCountdowns = const [],
  });

  bool get isEmpty =>
      activeCount == 0 &&
      monthlyEquivalent.isEmpty &&
      upcomingRenewals.isEmpty &&
      upcomingCountdowns.isEmpty;
}

/// 汇总订阅花费，并列出即将到来的续费和倒数日。
SpendSummary buildSpendSummary(
  List<CalendarItem> items,
  CivilDate today, {
  int renewalHorizon = 7,
  int countdownHorizon = 14,
}) {
  final monthly = <String, double>{};
  final yearly = <String, double>{};
  final due = <String, double>{};
  var active = 0;
  final renewals = <(CalendarItem, CivilDate)>[];
  final countdowns = <(CalendarItem, String)>[];
  final monthStart = CivilDate(today.year, today.month, 1);
  final monthEnd = endOfMonth(today);

  for (final it in items) {
    if (it.role == CalendarRole.subscription) {
      final st = resolvedStatus(it, today);
      final b = it.billing;
      if (st == SubscriptionStatus.active || st == SubscriptionStatus.trial) {
        active++;
        if (b != null) {
          final ccy = b.currency;
          final m = b.monthlyEquivalent();
          if (m != 0) {
            monthly[ccy] = (monthly[ccy] ?? 0) + m;
            yearly[ccy] = (yearly[ccy] ?? 0) + m * 12;
          }
        }
      }
      final next = nextBillingDate(it, today);
      if (next != null &&
          !next.isBefore(monthStart) &&
          !next.isAfter(monthEnd) &&
          b?.amount != null &&
          st != SubscriptionStatus.paused &&
          st != SubscriptionStatus.cancelled) {
        due[b!.currency] = (due[b.currency] ?? 0) + b.amount!;
      }
      if (next != null) {
        final days = today.differenceInDays(next);
        if (days >= 0 && days <= renewalHorizon) renewals.add((it, next));
      }
    } else if (it.role == CalendarRole.countdown ||
        it.role == CalendarRole.important) {
      final target = _isYearlyCount(it)
          ? nextAnniversary(it.startDate, today)
          : it.startDate;
      final days = today.differenceInDays(target);
      if (days >= 0 && days <= countdownHorizon) {
        countdowns.add((it, countdownHeadline(it, today)));
      }
    }
  }
  renewals.sort((a, b) => a.$2.compareTo(b.$2));
  countdowns.sort((a, b) {
    final da = today.differenceInDays(_targetOf(a.$1, today));
    final db = today.differenceInDays(_targetOf(b.$1, today));
    return da.compareTo(db);
  });
  return SpendSummary(
    monthlyEquivalent: monthly,
    yearlyEquivalent: yearly,
    dueThisMonth: due,
    activeCount: active,
    upcomingRenewals: renewals,
    upcomingCountdowns: countdowns,
  );
}

CivilDate _targetOf(CalendarItem it, CivilDate today) {
  return _isYearlyCount(it)
      ? nextAnniversary(it.startDate, today)
      : it.startDate;
}

/// 全天默认在当天 09:00 提醒；带时刻的按开始时刻。
class ReminderInstant {
  final String blockId;
  final String title;
  final String body;
  final DateTime when;
  final int offsetDays;
  const ReminderInstant({
    required this.blockId,
    required this.title,
    required this.body,
    required this.when,
    required this.offsetDays,
  });
}

List<ReminderInstant> reminderSchedule(
  CalendarItem item, {
  required DateTime now,
  int horizonDays = 90,
  int allDayHour = 9,
}) {
  if (item.id == null || item.id!.isEmpty || item.reminders.isEmpty) {
    return const [];
  }
  if (item.role == CalendarRole.subscription) {
    final st = resolvedStatus(item, CivilDate.fromDateTime(now));
    if (st == SubscriptionStatus.paused ||
        st == SubscriptionStatus.cancelled ||
        st == SubscriptionStatus.expired) {
      return const [];
    }
  }
  final from = CivilDate.fromDateTime(now);
  final to = from.addDays(horizonDays);
  final occ = expandItem(item, from.addDays(-366), to, today: from);
  final out = <ReminderInstant>[];
  final seen = <String>{};
  for (final o in occ) {
    for (final offset in item.reminders) {
      final fireDate = o.date.addDays(-offset);
      final DateTime when;
      if (item.allDay || o.startTime == null) {
        when = DateTime(
          fireDate.year,
          fireDate.month,
          fireDate.day,
          allDayHour,
        );
      } else {
        final hm = _parseHm(o.startTime!);
        when = DateTime(
          o.date.year,
          o.date.month,
          o.date.day,
          hm.$1,
          hm.$2,
        ).subtract(Duration(days: offset));
      }
      // 刚过点的提醒也保留，方便应用回到前台时补发。
      if (when.isBefore(now.subtract(const Duration(hours: 2)))) continue;
      if (when.isAfter(now.add(Duration(days: horizonDays)))) continue;
      final key = '${item.id}@${when.toIso8601String()}@$offset';
      if (!seen.add(key)) continue;
      out.add(
        ReminderInstant(
          blockId: item.id!,
          title: item.title,
          body: _reminderBody(item, o, offset),
          when: when,
          offsetDays: offset,
        ),
      );
    }
  }
  out.sort((a, b) => a.when.compareTo(b.when));
  return out;
}

String _reminderBody(CalendarItem item, CalOccurrence o, int offset) {
  if (item.role == CalendarRole.subscription) {
    final amt = item.billing?.amount;
    final ccy = item.billing?.currency ?? '';
    final money = amt == null ? '' : ' ${formatMoney(amt, ccy)}';
    if (offset == 0) return '今天扣款$money';
    return '还有 $offset 天扣款$money';
  }
  if (item.role == CalendarRole.countdown ||
      item.role == CalendarRole.important) {
    if (offset == 0) return '就是今天';
    return '还有 $offset 天';
  }
  if (offset == 0) return item.allDay ? '全天' : (o.startTime ?? '今天');
  return '还有 $offset 天${o.startTime == null ? '' : ' · ${o.startTime}'}';
}

(int, int) _parseHm(String s) {
  final p = s.split(':');
  final h = int.tryParse(p[0]) ?? 0;
  final m = p.length > 1 ? int.tryParse(p[1]) ?? 0 : 0;
  return (h.clamp(0, 23), m.clamp(0, 59));
}

int? _taskMs(Object? v) {
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v.trim());
  return null;
}

String? _asTime(Object? v) {
  if (v == null) return null;
  final s = v.toString().trim();
  if (s.isEmpty) return null;
  final m = RegExp(r'^(\d{1,2}):(\d{2})').firstMatch(s);
  if (m == null) return null;
  final h = int.parse(m.group(1)!);
  final min = int.parse(m.group(2)!);
  if (h > 23 || min > 59) return null;
  return '${h.toString().padLeft(2, '0')}:${min.toString().padLeft(2, '0')}';
}

double? _asDouble(Object? v) {
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v.trim());
  return null;
}

int _positiveInt(Object? v, int fallback) {
  final n = v is int ? v : int.tryParse(v?.toString() ?? '');
  if (n == null || n < 1) return fallback;
  return n;
}

T _enumFrom<T extends Enum>(List<T> values, Object? raw, T fallback) {
  final s = raw?.toString();
  if (s == null) return fallback;
  for (final v in values) {
    if (v.name == s) return v;
  }
  return fallback;
}

String formatMoney(double amount, String currency) {
  final ccy = currency.trim().isEmpty ? 'CNY' : currency.trim().toUpperCase();
  final body = amount == amount.roundToDouble()
      ? amount.toStringAsFixed(0)
      : amount.toStringAsFixed(2);
  return switch (ccy) {
    'CNY' || 'RMB' => '¥$body',
    'USD' => '\$$body',
    'EUR' => '€$body',
    'GBP' => '£$body',
    'JPY' => '¥$body',
    'HKD' => 'HK\$$body',
    'TWD' => 'NT\$$body',
    _ => '$ccy $body',
  };
}

String formatCivil(CivilDate d, {bool withWeekday = false}) {
  final s = '${d.year}年${d.month}月${d.day}日';
  if (!withWeekday) return s;
  const w = ['一', '二', '三', '四', '五', '六', '日'];
  return '$s 星期${w[d.weekday - 1]}';
}

const weekDayShort = ['一', '二', '三', '四', '五', '六', '日'];

/// 从块列表收集日历条目，并叠加 `kindRaw == task` 的只读日期（任务仪表盘对接）。
class CalendarIndex {
  final List<CalendarItem> items;
  final List<CalOccurrence> taskOverlay;

  const CalendarIndex(this.items, {this.taskOverlay = const []});

  static CalendarIndex fromBlocks(Iterable<Block> blocks) {
    final items = <CalendarItem>[];
    final tasks = <CalOccurrence>[];
    for (final b in blocks) {
      if (b.deleted || b.inTrash) continue;
      if (b.kind == BlockKind.calendar || b.kindRaw == 'calendar') {
        items.add(CalendarItem.fromBlock(b));
        continue;
      }
      if (b.kindRaw == 'task' || b.kind.name == 'task' || b.payload['is_task'] == true) {
        // 任务仪表盘的载荷用毫秒时间戳 start_at / due_at（本地时区）；
        // 兼容旧草案里的 YYYY-MM-DD 字符串字段。
        final p = b.payload;
        final startMs = _taskMs(p['start_at']);
        final dueMs = _taskMs(p['due_at']);
        final start = (startMs ?? dueMs) != null
            ? CivilDate.fromDateTime(DateTime.fromMillisecondsSinceEpoch((startMs ?? dueMs)!))
            : CivilDate.tryParse(p['start_date'] ?? p['due_date'] ?? p['end_date']);
        if (start == null) continue;
        final end = dueMs != null
            ? CivilDate.fromDateTime(DateTime.fromMillisecondsSinceEpoch(dueMs))
            : (CivilDate.tryParse(p['due_date'] ?? p['end_date']) ?? start);
        final allDay = p['all_day'] != false;
        String? hm(int? ms) {
          if (ms == null) return null;
          final d = DateTime.fromMillisecondsSinceEpoch(ms);
          return '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
        }
        final startTime = allDay ? null : (hm(startMs) ?? _asTime(p['start_time']));
        final endTime = allDay ? null : (hm(dueMs) ?? _asTime(p['end_time']));
        tasks.add(
          CalOccurrence(
            blockId: b.id,
            title: b.title.isEmpty ? '任务' : b.title,
            date: start,
            endDate: end.isBefore(start) ? start : end,
            allDay: allDay,
            startTime: startTime,
            endTime: endTime,
            source: 'task',
            color: (b.payload['color'] ?? 'teal').toString(),
            pinned: b.payload['pinned'] == true,
            subtitle: '任务',
          ),
        );
      }
    }
    return CalendarIndex(items, taskOverlay: tasks);
  }

  List<CalOccurrence> occurrences(
    CivilDate from,
    CivilDate to, {
    CivilDate? today,
    CalendarRole? role,
  }) {
    final out = <CalOccurrence>[];
    for (final it in items) {
      if (role != null && it.role != role) continue;
      out.addAll(expandItem(it, from, to, today: today));
    }
    for (final t in taskOverlay) {
      if (role != null) continue;
      if (t.endDate.isBefore(from) || t.date.isAfter(to)) continue;
      out.add(t);
    }
    out.sort((a, b) {
      final c = a.date.compareTo(b.date);
      if (c != 0) return c;
      final at = a.startTime ?? '99:99';
      final bt = b.startTime ?? '99:99';
      final tc = at.compareTo(bt);
      if (tc != 0) return tc;
      return a.title.compareTo(b.title);
    });
    return out;
  }

  List<CalOccurrence> onDay(
    CivilDate day, {
    CivilDate? today,
    CalendarRole? role,
  }) => occurrences(
    day,
    day,
    today: today,
    role: role,
  ).where((o) => o.covers(day)).toList();
}

bool isCalendarBlock(Block b) =>
    b.kind == BlockKind.calendar || b.kindRaw == 'calendar';
