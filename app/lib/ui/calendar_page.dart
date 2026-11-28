import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../calendar/calendar_item.dart';
import '../calendar/calendar_style.dart';
import '../calendar/lunar.dart';
import 'calendar_editor_page.dart';
import 'task_editor_page.dart';
import 'ds.dart';
import 'tokens.dart';
import 'glass.dart';
import 'motion.dart';

enum CalendarView { month, week, year, agenda, subscriptions, countdowns }

/// 日历主页面：月 / 周 / 年 / 议程 / 订阅 / 倒数，右下角新建。
class CalendarPage extends StatefulWidget {
  final String? focusBlockId;
  const CalendarPage({super.key, this.focusBlockId});

  @override
  State<CalendarPage> createState() => _CalendarPageState();
}

class _CalendarPageState extends State<CalendarPage> {
  CalendarView _view = CalendarView.month;
  late CivilDate _cursor;
  late CivilDate _selected;
  bool _showLunar = true;

  @override
  void initState() {
    super.initState();
    final t = CivilDate.today();
    _cursor = t;
    _selected = t;
  }

  CalendarIndex _index() =>
      CalendarIndex.fromBlocks(AppScope.of(context).sync.blocks);

  Future<void> _add({CalendarRole? role, CivilDate? date}) async {
    final created = await Navigator.of(context).push<bool>(
      fadeRoute(
        CalendarEditorPage(initialRole: role, initialDate: date ?? _selected),
      ),
    );
    if (created == true && mounted) setState(() {});
  }

  Future<void> _open(String id) async {
    await Navigator.of(
      context,
    ).push(fadeRoute(CalendarEditorPage(blockId: id)));
    if (mounted) setState(() {});
  }

  /// 日历上叠加的任务：打开任务编辑页（与任务仪表盘同一页面），返回后刷新日历。
  Future<void> _openTask(String id) async {
    final b = AppScope.of(context).sync.byId(id);
    if (b == null) return;
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => TaskEditorPage(blockId: id, parentId: b.parentId)),
    );
    if (mounted) setState(() {});
  }

  void _goToday() => setState(() {
    final t = CivilDate.today();
    _cursor = t;
    _selected = t;
  });

  void _shift(int months) => setState(() {
    _cursor = CivilDate(_cursor.year, _cursor.month, 1).addMonths(months);
    final last = DateTime(_cursor.year, _cursor.month + 1, 0).day;
    if (_selected.year != _cursor.year || _selected.month != _cursor.month) {
      _selected = CivilDate(
        _cursor.year,
        _cursor.month,
        _selected.day < last ? _selected.day : last,
      );
    }
  });

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final c = AppColors.of(context);
    final bg = Glass.scaffoldBg(context);
    return ListenableBuilder(
      listenable: Listenable.merge([s.sync, Glass.backdropListenable]),
      builder: (context, _) {
        final idx = _index();
        final today = CivilDate.today();
        final summary = buildSpendSummary(idx.items, today);
        return Scaffold(
          key: const Key('calendarPage'),
          backgroundColor: bg,
          appBar: AppBar(
            backgroundColor: bg,
            title: Text(_titleForView()),
            actions: [
              IconButton(
                key: const Key('calendarToday'),
                tooltip: '回到今天',
                icon: const Icon(CupertinoIcons.calendar_today),
                onPressed: _goToday,
              ),
              PopupMenuButton<String>(
                key: const Key('calendarMenu'),
                tooltip: '视图与选项',
                onSelected: (v) {
                  if (v == 'lunar') {
                    setState(() => _showLunar = !_showLunar);
                    return;
                  }
                  setState(() => _view = CalendarView.values.byName(v));
                },
                itemBuilder: (ctx) => [
                  for (final (id, label) in _viewItems)
                    CheckedPopupMenuItem(
                      value: id,
                      checked: _view.name == id,
                      child: Text(label),
                    ),
                  const PopupMenuDivider(),
                  CheckedPopupMenuItem(
                    value: 'lunar',
                    checked: _showLunar,
                    child: const Text('显示农历'),
                  ),
                ],
              ),
            ],
          ),
          floatingActionButton: FloatingActionButton(
            key: const Key('calendarAdd'),
            onPressed: () => _pickRoleAndAdd(),
            tooltip: '新建',
            child: const Icon(CupertinoIcons.add),
          ),
          body: Column(
            children: [
              if (summary.upcomingRenewals.isNotEmpty ||
                  summary.upcomingCountdowns.isNotEmpty)
                _upcomingBar(summary, c),
              Expanded(child: _body(idx, today, summary)),
            ],
          ),
        );
      },
    );
  }

  static const _viewItems = [
    ('month', '月'),
    ('week', '周'),
    ('year', '年'),
    ('agenda', '议程'),
    ('subscriptions', '订阅'),
    ('countdowns', '倒数'),
  ];

  String _titleForView() => switch (_view) {
    // 月 / 周视图下方已有「‹ 2026年11月 ›」导航，标题栏不再重复同一行字（信息层级）。
    CalendarView.month || CalendarView.week => '日历',
    CalendarView.year => '${_cursor.year}年',
    CalendarView.agenda => '议程',
    CalendarView.subscriptions => '订阅',
    CalendarView.countdowns => '倒数日',
  };

  Future<void> _pickRoleAndAdd() async {
    final role = await showCardSheet<CalendarRole>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final r in CalendarRole.values)
              ListTile(
                key: Key('calendarNew-${r.name}'),
                leading: Icon(_roleIcon(r)),
                title: Text(roleLabel(r)),
                subtitle: Text(_roleHint(r)),
                onTap: () => Navigator.pop(ctx, r),
              ),
            const SizedBox(height: Gap.m),
          ],
        ),
      ),
    );
    if (role != null && mounted) await _add(role: role);
  }

  IconData _roleIcon(CalendarRole r) => switch (r) {
    CalendarRole.subscription => CupertinoIcons.creditcard,
    CalendarRole.important => CupertinoIcons.pin_fill,
    CalendarRole.countdown => CupertinoIcons.hourglass,
    CalendarRole.event => CupertinoIcons.calendar,
  };

  String _roleHint(CalendarRole r) => switch (r) {
    CalendarRole.subscription => '会员、自动续费或单月 / 单季 / 单年',
    CalendarRole.important => '生日、纪念日和其他要记住的日子',
    CalendarRole.countdown => '出发、考试、截止日期',
    CalendarRole.event => '一次或重复的日程',
  };

  Widget _upcomingBar(SpendSummary summary, AppColors c) {
    final bits = <String>[];
    for (final (it, day) in summary.upcomingRenewals.take(3)) {
      bits.add('${it.title} ${countdownPhrase(CivilDate.today(), day)}扣费');
    }
    for (final (it, headline) in summary.upcomingCountdowns.take(3)) {
      bits.add('${it.title} $headline');
    }
    if (bits.isEmpty) return const SizedBox.shrink();
    return Material(
      color: c.fill,
      child: InkWell(
        key: const Key('calendarUpcoming'),
        onTap: () => setState(
          () => _view = bits.first.contains('扣费')
              ? CalendarView.subscriptions
              : CalendarView.countdowns,
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Gap.xl, Gap.m, Gap.xl, Gap.m),
          child: Row(
            children: [
              Icon(CupertinoIcons.bell, size: 16, color: c.warning),
              const SizedBox(width: Gap.m),
              Expanded(
                child: Text(
                  bits.join('  ·  '),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: c.text),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _body(CalendarIndex idx, CivilDate today, SpendSummary summary) {
    return switch (_view) {
      CalendarView.month => _monthView(idx, today),
      CalendarView.week => _weekView(idx, today),
      CalendarView.year => _yearView(idx, today),
      CalendarView.agenda => _agendaView(idx, today),
      CalendarView.subscriptions => _subsView(idx, today, summary),
      CalendarView.countdowns => _countView(idx, today),
    };
  }

  Widget _monthView(CalendarIndex idx, CivilDate today) {
    final first = startOfMonth(_cursor);
    final gridStart = startOfIsoWeek(first);
    final days = <CivilDate>[];
    var d = gridStart;
    while (days.length < 42) {
      days.add(d);
      d = d.addDays(1);
    }
    final occ = idx.occurrences(days.first, days.last, today: today);
    return Column(
      children: [
        _monthNav(),
        Padding(
          padding: const EdgeInsets.fromLTRB(Gap.m, 0, Gap.m, Gap.s),
          child: Row(
            children: [
              for (final w in weekDayShort)
                Expanded(
                  child: Center(
                    child: Text(
                      '周$w',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          flex: 5,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: Gap.s),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final cellW = constraints.maxWidth / 7;
                final cellH = constraints.maxHeight / 6;
                final ratio = cellW > 0 && cellH > 0 ? cellW / cellH : 0.85;
                return GridView.builder(
                  physics: const NeverScrollableScrollPhysics(),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 7,
                    childAspectRatio: ratio,
                  ),
                  itemCount: 42,
                  itemBuilder: (ctx, i) => _dayCell(days[i], today, first, occ),
                );
              },
            ),
          ),
        ),
        const Divider(height: 1),
        Expanded(flex: 4, child: _dayList(idx, _selected, today)),
      ],
    );
  }

  Widget _monthNav() {
    return SizedBox(
      height: Sizes.bar,
      child: Row(
        children: [
          IconButton(
            tooltip: '上个月',
            onPressed: () => _shift(-1),
            icon: const Icon(CupertinoIcons.chevron_left),
          ),
          Expanded(
            child: Center(
              child: Text(
                '${_cursor.year}年${_cursor.month}月',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
          ),
          IconButton(
            tooltip: '下个月',
            onPressed: () => _shift(1),
            icon: const Icon(CupertinoIcons.chevron_right),
          ),
        ],
      ),
    );
  }

  Widget _dayCell(
    CivilDate day,
    CivilDate today,
    CivilDate monthStart,
    List<CalOccurrence> all,
  ) {
    final c = AppColors.of(context);
    final inMonth =
        day.month == monthStart.month && day.year == monthStart.year;
    final selected = day == _selected;
    final isToday = day == today;
    final onDay = all.where((o) => o.covers(day)).toList();
    final lunar = _showLunar ? solarToLunar(day.dateTime) : null;
    final dark = Theme.of(context).brightness == Brightness.dark;
    // HIG 日历：今天 = 强调色实心圆；选中的其他日期 = 正文色实心圆；不再叠一层灰色方块。
    final circle = isToday ? c.accent : (selected ? c.text : null);
    return InkWell(
      key: Key('calendarDay-${day.ymd}'),
      borderRadius: BorderRadius.circular(AppRadius.m),
      onTap: () => setState(() {
        _selected = day;
        _cursor = day;
      }),
      onLongPress: () => _add(date: day),
      child: Semantics(
        selected: selected,
        label: '${day.month}月${day.day}日${isToday ? '，今天' : ''}',
        child: Padding(
          padding: const EdgeInsets.only(top: 2),
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.topCenter,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                AnimatedContainer(
                  duration: Motion.short3,
                  curve: MotionCurves.standard,
                  width: 28,
                  height: 28,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: circle ?? Colors.transparent,
                    shape: BoxShape.circle,
                  ),
                  child: Text(
                    '${day.day}',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: circle != null
                          ? (isToday ? Colors.white : c.bg.withValues(alpha: 1))
                          : (inMonth ? c.text : c.text3),
                      fontWeight: isToday || selected
                          ? FontWeight.w600
                          : FontWeight.w400,
                    ),
                  ),
                ),
                if (lunar != null)
                  Text(
                    lunar.shortLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      fontSize: 10,
                      color: inMonth ? c.text2 : c.text3,
                      height: 1.15,
                    ),
                  ),
                if (onDay.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 1),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        for (final o in onDay.take(3))
                          Container(
                            width: o.pinned ? 6 : 5,
                            height: o.pinned ? 6 : 5,
                            margin: const EdgeInsets.symmetric(horizontal: 0.5),
                            decoration: BoxDecoration(
                              shape: o.pinned
                                  ? BoxShape.rectangle
                                  : BoxShape.circle,
                              borderRadius: o.pinned
                                  ? BorderRadius.circular(1)
                                  : null,
                              color: calendarTint(o.color, dark: dark),
                            ),
                          ),
                        if (onDay.length > 3)
                          Text(
                            '+${onDay.length - 3}',
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(fontSize: 8, color: c.text3),
                          ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _dayList(CalendarIndex idx, CivilDate day, CivilDate today) {
    final items = idx.onDay(day, today: today);
    final c = AppColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(Gap.xl, Gap.m, Gap.xl, Gap.s),
          child: Text(
            formatCivil(day, withWeekday: true),
            style: Theme.of(context).textTheme.titleSmall,
          ),
        ),
        Expanded(
          child: items.isEmpty
              ? Center(
                  child: TextButton.icon(
                    onPressed: () => _add(date: day),
                    icon: const Icon(CupertinoIcons.add, size: 16),
                    label: const Text('在这天添加'),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.only(bottom: 88),
                  itemCount: items.length,
                  itemBuilder: (ctx, i) => _occTile(items[i], today, c),
                ),
        ),
      ],
    );
  }

  Widget _occTile(CalOccurrence o, CivilDate today, AppColors c) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final tint = calendarTint(o.color, dark: dark);
    final sub = <String>[];
    if (o.role != null) sub.add(roleLabel(o.role!));
    if (o.subtitle != null && o.subtitle!.isNotEmpty) sub.add(o.subtitle!);
    if (!o.allDay && o.startTime != null) sub.add(o.startTime!);
    if (o.item?.role == CalendarRole.subscription &&
        o.item?.billing?.amount != null) {
      sub.add(formatMoney(o.item!.billing!.amount!, o.item!.billing!.currency));
    }
    if (o.item != null &&
        (o.item!.role == CalendarRole.countdown ||
            o.item!.role == CalendarRole.important)) {
      sub.add(countdownHeadline(o.item!, today));
    }
    return ListTile(
      key: Key('calendarOcc-${o.blockId}-${o.date.ymd}'),
      leading: Container(
        width: 10,
        height: 36,
        decoration: BoxDecoration(
          color: tint,
          borderRadius: BorderRadius.circular(4),
        ),
      ),
      title: Text(
        o.title.isEmpty ? '无标题' : o.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: sub.isEmpty
          ? null
          : Text(sub.join(' · '), maxLines: 1, overflow: TextOverflow.ellipsis),
      onTap: o.source == 'task' ? () => _openTask(o.blockId) : () => _open(o.blockId),
    );
  }

  Widget _weekView(CalendarIndex idx, CivilDate today) {
    final start = startOfIsoWeek(_selected);
    final days = [for (var i = 0; i < 7; i++) start.addDays(i)];
    final occ = idx.occurrences(days.first, days.last, today: today);
    return Column(
      children: [
        SizedBox(
          height: Sizes.bar,
          child: Row(
            children: [
              IconButton(
                onPressed: () =>
                    setState(() => _selected = _selected.addDays(-7)),
                icon: const Icon(CupertinoIcons.chevron_left),
              ),
              Expanded(
                child: Center(
                  child: Text(
                    '${formatCivil(days.first)} – ${formatCivil(days.last)}',
                  ),
                ),
              ),
              IconButton(
                onPressed: () =>
                    setState(() => _selected = _selected.addDays(7)),
                icon: const Icon(CupertinoIcons.chevron_right),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.only(bottom: 88),
            itemCount: 7,
            itemBuilder: (ctx, i) {
              final day = days[i];
              final on = occ.where((o) => o.covers(day)).toList();
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                      Gap.xl,
                      Gap.l,
                      Gap.xl,
                      Gap.s,
                    ),
                    child: Text(
                      '${formatCivil(day, withWeekday: true)}${day == today ? ' · 今天' : ''}',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ),
                  if (on.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: Gap.xl),
                      child: Text(
                        '没有安排',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    )
                  else
                    for (final o in on)
                      _occTile(o, today, AppColors.of(context)),
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _yearView(CalendarIndex idx, CivilDate today) {
    return Column(
      children: [
        SizedBox(
          height: Sizes.bar,
          child: Row(
            children: [
              IconButton(
                onPressed: () =>
                    setState(() => _cursor = CivilDate(_cursor.year - 1, 1, 1)),
                icon: const Icon(CupertinoIcons.chevron_left),
              ),
              Expanded(child: Center(child: Text('${_cursor.year}年'))),
              IconButton(
                onPressed: () =>
                    setState(() => _cursor = CivilDate(_cursor.year + 1, 1, 1)),
                icon: const Icon(CupertinoIcons.chevron_right),
              ),
            ],
          ),
        ),
        Expanded(
          child: GridView.builder(
            padding: const EdgeInsets.fromLTRB(Gap.m, 0, Gap.m, 88),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              childAspectRatio: 0.9,
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
            ),
            itemCount: 12,
            itemBuilder: (ctx, i) =>
                _miniMonth(idx, today, CivilDate(_cursor.year, i + 1, 1)),
          ),
        ),
      ],
    );
  }

  Widget _miniMonth(CalendarIndex idx, CivilDate today, CivilDate month) {
    final c = AppColors.of(context);
    final first = startOfMonth(month);
    final start = startOfIsoWeek(first);
    final end = endOfMonth(month);
    final occ = idx.occurrences(first, end, today: today);
    return InkWell(
      onTap: () => setState(() {
        _cursor = month;
        _selected = month.year == today.year && month.month == today.month
            ? today
            : month;
        _view = CalendarView.month;
      }),
      child: Padding(
        padding: const EdgeInsets.all(Gap.s),
        child: Column(
          children: [
            Text(
              '${month.month}月',
              style: Theme.of(context).textTheme.labelLarge,
            ),
            const SizedBox(height: 4),
            Expanded(
              child: GridView.builder(
                physics: const NeverScrollableScrollPhysics(),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 7,
                ),
                itemCount: 42,
                itemBuilder: (ctx, i) {
                  final d = start.addDays(i);
                  final inMonth = d.month == month.month;
                  final has = inMonth && occ.any((o) => o.covers(d));
                  final isToday = d == today;
                  return Center(
                    child: Container(
                      width: 14,
                      height: 14,
                      alignment: Alignment.center,
                      decoration: isToday
                          ? BoxDecoration(
                              color: c.accent,
                              shape: BoxShape.circle,
                            )
                          : null,
                      child: Text(
                        '${d.day}',
                        style: TextStyle(
                          fontSize: 8,
                          color: isToday
                              ? Colors.white
                              : (inMonth ? (has ? c.accent : c.text) : c.text3),
                          fontWeight: has ? FontWeight.w600 : FontWeight.w400,
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _agendaView(CalendarIndex idx, CivilDate today) {
    final from = today;
    final to = today.addDays(60);
    final occ = idx.occurrences(from, to, today: today);
    if (occ.isEmpty) {
      return _empty('接下来两个月没有日程', '添加一条订阅、重要日期或倒数日', () => _add());
    }
    final groups = <CivilDate, List<CalOccurrence>>{};
    for (final o in occ) {
      groups.putIfAbsent(o.date, () => []).add(o);
    }
    final days = groups.keys.toList()..sort();
    final c = AppColors.of(context);
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 88),
      itemCount: days.length,
      itemBuilder: (ctx, i) {
        final day = days[i];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(Gap.xl, Gap.l, Gap.xl, Gap.s),
              child: Text(
                '${formatCivil(day, withWeekday: true)}${day == today ? ' · 今天' : ''}',
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
            for (final o in groups[day]!) _occTile(o, today, c),
          ],
        );
      },
    );
  }

  Widget _subsView(CalendarIndex idx, CivilDate today, SpendSummary summary) {
    final c = AppColors.of(context);
    final subs = idx.items
        .where((i) => i.role == CalendarRole.subscription)
        .toList();
    subs.sort((a, b) {
      final na = nextBillingDate(a, today);
      final nb = nextBillingDate(b, today);
      if (na == null && nb == null) return a.title.compareTo(b.title);
      if (na == null) return 1;
      if (nb == null) return -1;
      return na.compareTo(nb);
    });
    if (subs.isEmpty) {
      return _empty(
        '还没有订阅',
        '记下会员的周期和金额，续费前会提醒你',
        () => _add(role: CalendarRole.subscription),
      );
    }
    String moneyMap(Map<String, double> m) =>
        m.entries.map((e) => formatMoney(e.value, e.key)).join('  ');
    return ListView(
      padding: const EdgeInsets.fromLTRB(Gap.xl, Gap.m, Gap.xl, 88),
      children: [
        _statCard(c, [
          (
            '每月折合',
            moneyMap(summary.monthlyEquivalent).isEmpty
                ? '—'
                : moneyMap(summary.monthlyEquivalent),
          ),
          (
            '每年折合',
            moneyMap(summary.yearlyEquivalent).isEmpty
                ? '—'
                : moneyMap(summary.yearlyEquivalent),
          ),
          (
            '本月应付',
            moneyMap(summary.dueThisMonth).isEmpty
                ? '—'
                : moneyMap(summary.dueThisMonth),
          ),
        ], '${summary.activeCount} 个使用中'),
        const SizedBox(height: Gap.l),
        for (final it in subs) _subTile(it, today, c),
      ],
    );
  }

  Widget _statCard(AppColors c, List<(String, String)> rows, String footnote) {
    return Container(
      padding: const EdgeInsets.all(Gap.l),
      decoration: BoxDecoration(
        color: c.fill,
        borderRadius: BorderRadius.circular(AppRadius.l),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final (label, value) in rows)
            Padding(
              padding: const EdgeInsets.only(bottom: Gap.s),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      label,
                      style: Theme.of(
                        context,
                      ).textTheme.bodyMedium?.copyWith(color: c.text2),
                    ),
                  ),
                  Text(value, style: Theme.of(context).textTheme.titleSmall),
                ],
              ),
            ),
          Text(footnote, style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }

  Widget _subTile(CalendarItem it, CivilDate today, AppColors c) {
    final st = resolvedStatus(it, today);
    final next = nextBillingDate(it, today);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final bits = <String>[
      it.billing?.cycleLabel ?? '',
      if (it.billing?.autoRenew == true) '自动续费',
      statusLabel(st),
    ];
    if (it.billing?.amount != null) {
      bits.add(formatMoney(it.billing!.amount!, it.billing!.currency));
    }
    if (next != null) {
      bits.add('下次 ${formatCivil(next)} · ${countdownPhrase(today, next)}');
    }
    return ListTile(
      key: Key('calendarSub-${it.id}'),
      contentPadding: EdgeInsets.zero,
      leading: CircleAvatar(
        backgroundColor: calendarTint(it.displayColor, dark: dark),
        child: Text(
          it.title.isEmpty ? '订' : it.title.characters.first,
          style: const TextStyle(color: Colors.white),
        ),
      ),
      title: Text(it.title.isEmpty ? '无标题' : it.title),
      subtitle: Text(
        bits.where((s) => s.isNotEmpty).join(' · '),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      onTap: it.id == null ? null : () => _open(it.id!),
    );
  }

  Widget _countView(CalendarIndex idx, CivilDate today) {
    final items = idx.items
        .where(
          (i) =>
              i.role == CalendarRole.countdown ||
              i.role == CalendarRole.important,
        )
        .toList();
    if (items.isEmpty) {
      return _empty(
        '还没有倒数日',
        '记下出发、考试或纪念日，到点会提醒你',
        () => _add(role: CalendarRole.countdown),
      );
    }
    items.sort((a, b) {
      final ta = _isYearly(a)
          ? nextAnniversary(a.startDate, today)
          : a.startDate;
      final tb = _isYearly(b)
          ? nextAnniversary(b.startDate, today)
          : b.startDate;
      final da = today.differenceInDays(ta);
      final db = today.differenceInDays(tb);
      final aFuture = da >= 0, bFuture = db >= 0;
      if (aFuture != bFuture) return aFuture ? -1 : 1;
      return aFuture ? da.compareTo(db) : db.compareTo(da);
    });
    final dark = Theme.of(context).brightness == Brightness.dark;
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(Gap.xl, Gap.m, Gap.xl, 88),
      itemCount: items.length,
      itemBuilder: (ctx, i) {
        final it = items[i];
        final target = _isYearly(it)
            ? nextAnniversary(it.startDate, today)
            : it.startDate;
        final days = today.differenceInDays(target);
        final number = days == 0 ? '今' : '${days.abs()}';
        final unit = days == 0 ? '天' : '天';
        final tone = days < 0 ? '已过' : (days == 0 ? '就是' : '还有');
        return Card(
          key: Key('calendarCount-${it.id}'),
          margin: const EdgeInsets.only(bottom: Gap.m),
          child: InkWell(
            onTap: it.id == null ? null : () => _open(it.id!),
            child: Padding(
              padding: const EdgeInsets.all(Gap.l),
              child: Row(
                children: [
                  Container(
                    width: 72,
                    padding: const EdgeInsets.symmetric(vertical: Gap.s),
                    decoration: BoxDecoration(
                      color: calendarTint(
                        it.displayColor,
                        dark: dark,
                      ).withValues(alpha: 0.16),
                      borderRadius: BorderRadius.circular(AppRadius.m),
                    ),
                    child: Column(
                      children: [
                        Text(
                          tone,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        Text(
                          number,
                          style: Theme.of(context).textTheme.headlineMedium
                              ?.copyWith(
                                fontWeight: FontWeight.w600,
                                height: 1.05,
                              ),
                        ),
                        Text(
                          unit,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: Gap.l),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          it.title.isEmpty ? '无标题' : it.title,
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${formatCivil(target, withWeekday: true)} · ${countdownHeadline(it, today)}',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  bool _isYearly(CalendarItem it) =>
      it.count.repeatYearly || it.recur.freq == RecurFreq.yearly;

  Widget _empty(String title, String sub, VoidCallback onAdd) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Gap.x3),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: Gap.s),
            Text(
              sub,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: Gap.l),
            FilledButton.icon(
              onPressed: onAdd,
              icon: const Icon(CupertinoIcons.add, size: 16),
              label: const Text('添加'),
            ),
          ],
        ),
      ),
    );
  }
}
