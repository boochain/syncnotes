import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../calendar/calendar_item.dart';
import '../calendar/calendar_style.dart';
import '../models/block.dart';
import '../sync/sync_client.dart';
import 'ds.dart';
import 'glass.dart';

/// 新建或编辑一条日历记录。返回 true 表示已保存。
class CalendarEditorPage extends StatefulWidget {
  final String? blockId;
  final CalendarRole? initialRole;
  final CivilDate? initialDate;
  const CalendarEditorPage({
    super.key,
    this.blockId,
    this.initialRole,
    this.initialDate,
  });

  @override
  State<CalendarEditorPage> createState() => _CalendarEditorPageState();
}

class _CalendarEditorPageState extends State<CalendarEditorPage> {
  late CalendarRole _role;
  final _title = TextEditingController();
  final _notes = TextEditingController();
  final _amount = TextEditingController();
  final _category = TextEditingController();
  final _url = TextEditingController();
  late CivilDate _start;
  CivilDate? _end;
  bool _allDay = true;
  String? _startTime;
  String? _endTime;
  String _timezone = 'Asia/Shanghai';
  String _color = '';
  bool _pinned = false;
  List<int> _reminders = const [0, 1, 7];
  RecurFreq _freq = RecurFreq.none;
  int _recurInterval = 1;
  CivilDate? _until;
  BillingCycle _cycle = BillingCycle.monthly;
  bool _autoRenew = true;
  String _currency = 'CNY';
  SubscriptionStatus _status = SubscriptionStatus.active;
  int _interval = 1;
  IntervalUnit _intervalUnit = IntervalUnit.month;
  CivilDate? _trialEnds;
  CountMode _countMode = CountMode.both;
  bool _repeatYearly = false;
  bool _showAge = false;
  bool _more = false;
  bool _dirty = false;

  @override
  void initState() {
    super.initState();
    _role = widget.initialRole ?? CalendarRole.event;
    _start = widget.initialDate ?? CivilDate.today();
    _applyRoleDefaults(_role, first: true);
  }

  bool _loaded = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loaded) return;
    _loaded = true;
    final id = widget.blockId;
    if (id == null) return;
    final b = AppScope.of(context).sync.byId(id);
    if (b == null || !isCalendarBlock(b)) return;
    final it = CalendarItem.fromBlock(b);
    _role = it.role;
    _title.text = it.title;
    _notes.text = it.notes;
    _start = it.startDate;
    _end = it.endDate;
    _allDay = it.allDay;
    _startTime = it.startTime;
    _endTime = it.endTime;
    _timezone = it.timezone;
    _color = it.displayColor;
    _pinned = it.pinned;
    _category.text = it.category;
    _reminders = List.of(it.reminders);
    _freq = it.recur.freq;
    _recurInterval = it.recur.interval;
    _until = it.recur.until;
    _countMode = it.count.mode;
    _repeatYearly = it.count.repeatYearly;
    _showAge = it.count.showAge;
    final bll = it.billing;
    if (bll != null) {
      _cycle = bll.cycle;
      _autoRenew = bll.autoRenew;
      _currency = bll.currency;
      _status = bll.status;
      _interval = bll.interval;
      _intervalUnit = bll.intervalUnit;
      _trialEnds = bll.trialEnds;
      _url.text = bll.url;
      if (bll.amount != null) {
        final a = bll.amount!;
        _amount.text = a == a.roundToDouble()
            ? a.toStringAsFixed(0)
            : a.toStringAsFixed(2);
      }
    }
    if (_color.isEmpty) _color = CalendarItem.defaultColorFor(_role);
  }

  void _applyRoleDefaults(CalendarRole role, {bool first = false}) {
    _role = role;
    if (_color.isEmpty || first) _color = CalendarItem.defaultColorFor(role);
    if (role == CalendarRole.subscription) {
      _allDay = true;
      _reminders = const [1, 7];
    } else if (role == CalendarRole.countdown ||
        role == CalendarRole.important) {
      _reminders = const [0, 1, 7];
    } else {
      _reminders = const [0, 1];
    }
  }

  @override
  void dispose() {
    _title.dispose();
    _notes.dispose();
    _amount.dispose();
    _category.dispose();
    _url.dispose();
    super.dispose();
  }

  CalendarItem _buildItem() {
    Billing? billing;
    if (_role == CalendarRole.subscription) {
      billing = Billing(
        cycle: _cycle,
        interval: _interval,
        intervalUnit: _intervalUnit,
        autoRenew: _autoRenew,
        amount: double.tryParse(_amount.text.trim()),
        currency: _currency,
        status: _status,
        trialEnds: _trialEnds,
        url: _url.text.trim(),
      );
    }
    return CalendarItem(
      id: widget.blockId,
      title: _title.text.trim(),
      role: _role,
      allDay: _allDay,
      startDate: _start,
      endDate: _end,
      startTime: _allDay ? null : _startTime,
      endTime: _allDay ? null : _endTime,
      timezone: _timezone,
      notes: _notes.text.trim(),
      color: _color,
      pinned: _pinned,
      category: _category.text.trim(),
      reminders: _reminders,
      recur: Recurrence(freq: _freq, interval: _recurInterval, until: _until),
      billing: billing,
      count: CountSpec(
        mode: _countMode,
        repeatYearly: _repeatYearly,
        showAge: _showAge,
      ),
    );
  }

  Future<void> _save() async {
    final title = _title.text.trim();
    if (title.isEmpty) {
      showToast(context, '请填写标题');
      return;
    }
    final item = _buildItem();
    final sync = AppScope.of(context).sync;
    upsertCalendar(sync, item);
    if (mounted) Navigator.of(context).pop(true);
  }

  Future<void> _delete() async {
    final id = widget.blockId;
    if (id == null) return;
    final ok = await confirmDanger(
      context,
      title: '移入回收站',
      message: '这条日历记录会移到回收站，可以随时恢复。',
      confirm: '移入回收站',
    );
    if (!ok || !mounted) return;
    AppScope.of(context).sync.delete(id);
    if (mounted) Navigator.of(context).pop(true);
  }

  Future<CivilDate?> _pickDate(CivilDate current) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: current.dateTime,
      firstDate: DateTime(1970, 1, 1),
      lastDate: DateTime(2100, 12, 31),
    );
    if (picked == null) return null;
    return CivilDate.fromDateTime(picked);
  }

  Future<String?> _pickTime(String? current) async {
    final parts = (current ?? '09:00').split(':');
    final h = int.tryParse(parts.first) ?? 9;
    final m = int.tryParse(parts.length > 1 ? parts[1] : '0') ?? 0;
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: h, minute: m),
    );
    if (picked == null) return current;
    final hh = picked.hour.toString().padLeft(2, '0');
    final mm = picked.minute.toString().padLeft(2, '0');
    return '$hh:$mm';
  }

  void _mark() => setState(() => _dirty = true);

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final tt = Theme.of(context).textTheme;
    final bg = Glass.scaffoldBg(context);
    final isNew = widget.blockId == null;
    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final leave = await showDialog<bool>(
          context: context,
          builder: (d) => AlertDialog(
            title: const Text('放弃更改？'),
            content: const Text('未保存的修改会丢失。'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(d, false),
                child: const Text('继续编辑'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(d, true),
                child: const Text('放弃'),
              ),
            ],
          ),
        );
        if (leave == true && context.mounted) Navigator.of(context).pop();
      },
      child: Scaffold(
        key: const Key('calendarEditor'),
        backgroundColor: bg,
        appBar: AppBar(
          backgroundColor: bg,
          title: Text(
            isNew ? '新建${roleLabel(_role)}' : '编辑${roleLabel(_role)}',
          ),
          actions: [
            TextButton(
              key: const Key('calendarSave'),
              onPressed: _save,
              child: const Text('保存'),
            ),
            const SizedBox(width: Gap.s),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(Gap.xl, Gap.m, Gap.xl, 48),
          children: [
            Text('类型', style: tt.bodySmall?.copyWith(color: c.text2)),
            const SizedBox(height: Gap.s),
            Wrap(
              spacing: Gap.s,
              runSpacing: Gap.s,
              children: [
                for (final r in CalendarRole.values)
                  ChoiceChip(
                    key: Key('calendarRole-${r.name}'),
                    label: Text(roleLabel(r)),
                    selected: _role == r,
                    onSelected: (_) => setState(() {
                      _applyRoleDefaults(r);
                      _dirty = true;
                    }),
                  ),
              ],
            ),
            const SizedBox(height: Gap.l),
            TextField(
              key: const Key('calendarTitle'),
              controller: _title,
              autofocus: isNew,
              textInputAction: TextInputAction.next,
              onChanged: (_) => _mark(),
              decoration: const InputDecoration(
                labelText: '标题',
                hintText: '例如 Netflix、春节、出发日',
              ),
            ),
            if (_role == CalendarRole.subscription) ...[
              const SizedBox(height: Gap.l),
              _presetRow(),
              const SizedBox(height: Gap.m),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      key: const Key('calendarAmount'),
                      controller: _amount,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      onChanged: (_) => _mark(),
                      decoration: const InputDecoration(labelText: '金额'),
                    ),
                  ),
                  const SizedBox(width: Gap.m),
                  SizedBox(
                    width: 112,
                    child: DropdownButtonFormField<String>(
                      key: const Key('calendarCurrency'),
                      initialValue: currencyChoices.contains(_currency)
                          ? _currency
                          : 'CNY',
                      items: [
                        for (final x in currencyChoices)
                          DropdownMenuItem(value: x, child: Text(x)),
                      ],
                      onChanged: (v) => setState(() {
                        if (v != null) _currency = v;
                        _dirty = true;
                      }),
                      decoration: const InputDecoration(labelText: '币种'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: Gap.l),
              DropdownButtonFormField<BillingCycle>(
                initialValue: _cycle,
                items: [
                  for (final x in BillingCycle.values)
                    DropdownMenuItem(value: x, child: Text(_cycleName(x))),
                ],
                onChanged: (v) => setState(() {
                  if (v != null) _cycle = v;
                  _dirty = true;
                }),
                decoration: const InputDecoration(labelText: '周期'),
              ),
              if (_cycle == BillingCycle.custom) ...[
                const SizedBox(height: Gap.m),
                Row(
                  children: [
                    Expanded(
                      child: TextFormField(
                        initialValue: '$_interval',
                        keyboardType: TextInputType.number,
                        onChanged: (v) {
                          _interval = int.tryParse(v) ?? 1;
                          _mark();
                        },
                        decoration: const InputDecoration(labelText: '间隔'),
                      ),
                    ),
                    const SizedBox(width: Gap.m),
                    Expanded(
                      child: DropdownButtonFormField<IntervalUnit>(
                        initialValue: _intervalUnit,
                        items: const [
                          DropdownMenuItem(
                            value: IntervalUnit.day,
                            child: Text('天'),
                          ),
                          DropdownMenuItem(
                            value: IntervalUnit.week,
                            child: Text('周'),
                          ),
                          DropdownMenuItem(
                            value: IntervalUnit.month,
                            child: Text('月'),
                          ),
                          DropdownMenuItem(
                            value: IntervalUnit.year,
                            child: Text('年'),
                          ),
                        ],
                        onChanged: (v) => setState(() {
                          if (v != null) _intervalUnit = v;
                          _dirty = true;
                        }),
                        decoration: const InputDecoration(labelText: '单位'),
                      ),
                    ),
                  ],
                ),
              ],
              SwitchListTile(
                key: const Key('calendarAutoRenew'),
                contentPadding: EdgeInsets.zero,
                title: const Text('自动续费'),
                subtitle: Text(_autoRenew ? '到期后按周期继续' : '到结束日为止，适合单月、单季、单年'),
                value: _autoRenew,
                onChanged: (v) => setState(() {
                  _autoRenew = v;
                  _dirty = true;
                }),
              ),
              DropdownButtonFormField<SubscriptionStatus>(
                initialValue: _status,
                items: [
                  for (final s in SubscriptionStatus.values)
                    DropdownMenuItem(value: s, child: Text(statusLabel(s))),
                ],
                onChanged: (v) => setState(() {
                  if (v != null) _status = v;
                  _dirty = true;
                }),
                decoration: const InputDecoration(labelText: '状态'),
              ),
            ],
            const SizedBox(height: Gap.l),
            _dateTile(
              key: const Key('calendarStart'),
              label: _role == CalendarRole.subscription ? '首次扣费 / 起始日' : '开始日期',
              value: formatCivil(_start, withWeekday: true),
              onTap: () async {
                final d = await _pickDate(_start);
                if (d != null)
                  setState(() {
                    _start = d;
                    if (_end != null && _end!.isBefore(_start)) _end = _start;
                    _dirty = true;
                  });
              },
            ),
            _dateTile(
              key: const Key('calendarEnd'),
              label: _role == CalendarRole.subscription
                  ? '结束日（可选）'
                  : '结束日期（可选）',
              value: _end == null ? '无' : formatCivil(_end!, withWeekday: true),
              onTap: () async {
                final d = await _pickDate(_end ?? _start);
                if (d != null)
                  setState(() {
                    _end = d;
                    _dirty = true;
                  });
              },
              trailing: _end == null
                  ? null
                  : IconButton(
                      tooltip: '清除结束日',
                      icon: const Icon(CupertinoIcons.xmark_circle, size: 18),
                      onPressed: () => setState(() {
                        _end = null;
                        _dirty = true;
                      }),
                    ),
            ),
            if (_role != CalendarRole.subscription)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('全天'),
                value: _allDay,
                onChanged: (v) => setState(() {
                  _allDay = v;
                  if (!v) _startTime ??= '09:00';
                  _dirty = true;
                }),
              ),
            if (!_allDay && _role != CalendarRole.subscription)
              Row(
                children: [
                  Expanded(
                    child: _dateTile(
                      label: '开始时刻',
                      value: _startTime ?? '09:00',
                      onTap: () async {
                        final t = await _pickTime(_startTime);
                        if (t != null)
                          setState(() {
                            _startTime = t;
                            _dirty = true;
                          });
                      },
                    ),
                  ),
                  const SizedBox(width: Gap.m),
                  Expanded(
                    child: _dateTile(
                      label: '结束时刻',
                      value: _endTime ?? '无',
                      onTap: () async {
                        final t = await _pickTime(_endTime ?? _startTime);
                        if (t != null)
                          setState(() {
                            _endTime = t;
                            _dirty = true;
                          });
                      },
                    ),
                  ),
                ],
              ),
            if (_role == CalendarRole.event) ...[
              const SizedBox(height: Gap.m),
              DropdownButtonFormField<RecurFreq>(
                initialValue: _freq,
                items: const [
                  DropdownMenuItem(value: RecurFreq.none, child: Text('不重复')),
                  DropdownMenuItem(value: RecurFreq.daily, child: Text('每天')),
                  DropdownMenuItem(value: RecurFreq.weekly, child: Text('每周')),
                  DropdownMenuItem(value: RecurFreq.monthly, child: Text('每月')),
                  DropdownMenuItem(value: RecurFreq.yearly, child: Text('每年')),
                ],
                onChanged: (v) => setState(() {
                  if (v != null) _freq = v;
                  _dirty = true;
                }),
                decoration: const InputDecoration(labelText: '重复'),
              ),
            ],
            if (_role == CalendarRole.countdown ||
                _role == CalendarRole.important) ...[
              SwitchListTile(
                key: const Key('calendarRepeatYearly'),
                contentPadding: EdgeInsets.zero,
                title: const Text('每年重复'),
                subtitle: const Text('生日、纪念日会自动转到下一年，并显示即将到来的岁数或周年'),
                value: _repeatYearly,
                onChanged: (v) => setState(() {
                  _repeatYearly = v;
                  _dirty = true;
                }),
              ),
              if (_repeatYearly)
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('显示年龄 / 周年'),
                  value: _showAge,
                  onChanged: (v) => setState(() {
                    _showAge = v;
                    _dirty = true;
                  }),
                ),
            ],
            const SizedBox(height: Gap.l),
            Text('颜色', style: tt.bodySmall?.copyWith(color: c.text2)),
            const SizedBox(height: Gap.s),
            Wrap(
              spacing: Gap.s,
              children: [
                for (final name in calendarColorNames)
                  GestureDetector(
                    onTap: () => setState(() {
                      _color = name;
                      _dirty = true;
                    }),
                    child: Container(
                      width: 28,
                      height: 28,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: calendarTint(
                          name,
                          dark: Theme.of(context).brightness == Brightness.dark,
                        ),
                        border: _color == name
                            ? Border.all(color: c.text, width: 2)
                            : null,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: Gap.l),
            Text(
              '提醒（提前几天，0 为当天上午 9 点）',
              style: tt.bodySmall?.copyWith(color: c.text2),
            ),
            const SizedBox(height: Gap.s),
            Wrap(
              spacing: Gap.s,
              children: [
                for (final d in const [0, 1, 3, 7, 14, 30])
                  FilterChip(
                    label: Text(d == 0 ? '当天' : '$d 天'),
                    selected: _reminders.contains(d),
                    onSelected: (on) => setState(() {
                      final next = List<int>.from(_reminders);
                      if (on) {
                        if (!next.contains(d)) next.add(d);
                      } else {
                        next.remove(d);
                      }
                      next.sort();
                      _reminders = next;
                      _dirty = true;
                    }),
                  ),
              ],
            ),
            const SizedBox(height: Gap.l),
            TextButton(
              onPressed: () => setState(() => _more = !_more),
              child: Text(_more ? '收起更多选项' : '更多选项'),
            ),
            if (_more) ...[
              TextField(
                controller: _category,
                onChanged: (_) => _mark(),
                decoration: const InputDecoration(
                  labelText: '分类',
                  hintText: '娱乐、工作、生活…',
                ),
              ),
              const SizedBox(height: Gap.m),
              if (_role == CalendarRole.subscription)
                TextField(
                  controller: _url,
                  onChanged: (_) => _mark(),
                  decoration: const InputDecoration(labelText: '管理页链接（可选）'),
                ),
              if (_role == CalendarRole.subscription)
                const SizedBox(height: Gap.m),
              if (_role == CalendarRole.subscription)
                _dateTile(
                  label: '试用结束日（可选）',
                  value: _trialEnds == null ? '无' : formatCivil(_trialEnds!),
                  onTap: () async {
                    final d = await _pickDate(_trialEnds ?? _start);
                    if (d != null)
                      setState(() {
                        _trialEnds = d;
                        _status = SubscriptionStatus.trial;
                        _dirty = true;
                      });
                  },
                ),
              DropdownButtonFormField<String>(
                initialValue: commonTimezones.contains(_timezone)
                    ? _timezone
                    : 'Asia/Shanghai',
                items: [
                  for (final z in commonTimezones)
                    DropdownMenuItem(value: z, child: Text(z)),
                ],
                onChanged: (v) => setState(() {
                  if (v != null) _timezone = v;
                  _dirty = true;
                }),
                decoration: const InputDecoration(labelText: '时区'),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('在月历上用图针标出'),
                value: _pinned,
                onChanged: (v) => setState(() {
                  _pinned = v;
                  _dirty = true;
                }),
              ),
              TextField(
                controller: _notes,
                onChanged: (_) => _mark(),
                minLines: 2,
                maxLines: 5,
                decoration: const InputDecoration(labelText: '备注'),
              ),
            ],
            if (widget.blockId != null) ...[
              const SizedBox(height: Gap.x3),
              TextButton(
                key: const Key('calendarDelete'),
                onPressed: _delete,
                child: Text('移入回收站', style: TextStyle(color: c.danger)),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _presetRow() {
    const presets = <(String, BillingCycle, String)>[
      ('Netflix', BillingCycle.monthly, 'red'),
      ('Spotify', BillingCycle.monthly, 'green'),
      ('Apple iCloud+', BillingCycle.monthly, 'blue'),
      ('爱奇艺', BillingCycle.monthly, 'green'),
      ('腾讯视频', BillingCycle.monthly, 'orange'),
      ('哔哩哔哩大会员', BillingCycle.monthly, 'pink'),
      ('Microsoft 365', BillingCycle.yearly, 'blue'),
      ('京东 PLUS', BillingCycle.yearly, 'red'),
      ('淘宝 88VIP', BillingCycle.yearly, 'orange'),
      ('ChatGPT Plus', BillingCycle.monthly, 'green'),
    ];
    return SizedBox(
      height: 36,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          for (final (name, cycle, color) in presets)
            Padding(
              padding: const EdgeInsets.only(right: Gap.s),
              child: ActionChip(
                label: Text(name, style: const TextStyle(fontSize: 12)),
                onPressed: () => setState(() {
                  _title.text = name;
                  _cycle = cycle;
                  _color = color;
                  _dirty = true;
                }),
              ),
            ),
        ],
      ),
    );
  }

  Widget _dateTile({
    Key? key,
    required String label,
    required String value,
    required VoidCallback onTap,
    Widget? trailing,
  }) {
    final c = AppColors.of(context);
    return ListTile(
      key: key,
      contentPadding: EdgeInsets.zero,
      title: Text(
        label,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(color: c.text2),
      ),
      subtitle: Text(value, style: Theme.of(context).textTheme.bodyLarge),
      trailing: trailing,
      onTap: onTap,
    );
  }

  String _cycleName(BillingCycle c) => switch (c) {
    BillingCycle.weekly => '每周',
    BillingCycle.monthly => '每月 / 单月',
    BillingCycle.quarterly => '每季 / 单季',
    BillingCycle.yearly => '每年 / 单年',
    BillingCycle.custom => '自定义',
    BillingCycle.once => '一次性',
  };
}

/// 把日历条目写入同步队列（新建或更新）。
Block upsertCalendar(SyncClient sync, CalendarItem item) {
  if (item.id == null || item.id!.isEmpty || sync.byId(item.id!) == null) {
    return sync.create(
      kind: BlockKind.calendar,
      title: item.title,
      payload: item.toPayload(),
      viewedMode: ViewedMode.global,
    );
  }
  return sync.update(item.id!, title: item.title, payload: item.toPayload())!;
}
