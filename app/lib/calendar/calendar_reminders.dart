import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/block.dart';
import '../platform/notifications.dart';
import '../sync/sync_client.dart';
import 'calendar_item.dart';

/// 日历提醒：SyncNotes 自己的日历，不读写系统日历、不依赖系统提醒事项。
///
/// - 应用运行时：数据变化 + 每分钟一次检查，到点立刻弹本地通知（桌面常驻托盘时靠这个）。
/// - Android：未来 90 天内最近的 [maxScheduled] 条提醒用本地通知预约，应用被杀也会按时弹出；
///   使用非精确闹钟，不申请 SCHEDULE_EXACT_ALARM。
/// - 已经弹过 / 已经预约过的提醒记在本机（最多 [maxRemembered] 条），重启后不会重复弹。
class CalendarReminders {
  CalendarReminders._();

  static const horizonDays = 90;
  static const channelId = 'syncnotes_calendar';
  static const idBase = 71000;
  static const maxScheduled = 48;
  static const maxRemembered = 400;
  static const _prefFired = 'calendar_reminders_fired';
  static const _prefScheduled = 'calendar_reminders_scheduled';
  static DateTime? _lastRun;
  static final Set<String> _fired = {};
  static bool _loaded = false;

  static String keyOf(ReminderInstant r) =>
      '${r.blockId}@${r.when.toIso8601String()}@${r.offsetDays}';

  static Future<SharedPreferences?> _prefs() async {
    try {
      return await SharedPreferences.getInstance();
    } catch (_) {
      return null;
    }
  }

  static Future<void> _load() async {
    if (_loaded) return;
    _loaded = true;
    final p = await _prefs();
    _fired.addAll(p?.getStringList(_prefFired) ?? const []);
  }

  static Future<void> _save() async {
    final p = await _prefs();
    if (p == null) return;
    var list = _fired.toList();
    if (list.length > maxRemembered) list = list.sublist(list.length - maxRemembered);
    await p.setStringList(_prefFired, list);
  }

  /// 根据当前块算出应调度的提醒（纯计算，便于测试）。
  static List<ReminderInstant> plan(Iterable<Block> blocks, DateTime now) {
    final out = <ReminderInstant>[];
    for (final b in blocks) {
      if (b.deleted || b.inTrash) continue;
      if (!isCalendarBlock(b)) continue;
      out.addAll(
        reminderSchedule(
          CalendarItem.fromBlock(b),
          now: now,
          horizonDays: horizonDays,
        ),
      );
    }
    out.sort((a, b) => a.when.compareTo(b.when));
    return out;
  }

  /// 扫描并弹出已到期提醒。返回弹出条数。
  static Future<int> sync(
    SyncClient client, {
    DateTime? now,
    Future<void> Function(ReminderInstant)? show,
  }) async {
    final t = now ?? DateTime.now();
    _lastRun = t;
    final persist = show == null;
    if (persist) await _load();
    final items = plan(client.blocks, t);
    var n = 0;
    final showFn = show ?? _defaultShow;
    for (final r in items) {
      // 到期前 1 分钟到过后 2 小时内补发一次，避免进程被杀后漏掉。
      if (r.when.isAfter(t.add(const Duration(minutes: 1)))) continue;
      if (r.when.isBefore(t.subtract(const Duration(hours: 2)))) continue;
      if (!_fired.add(keyOf(r))) continue;
      await showFn(r);
      n++;
    }
    if (persist && n > 0) await _save();
    return n;
  }

  static Future<void> _defaultShow(ReminderInstant r) async {
    await Notifier.showReminder(
      title: r.title,
      body: r.body,
      payload: r.blockId,
      id: _stableId(r),
    );
  }

  static int _stableId(ReminderInstant r) {
    final h = Object.hash(
      r.blockId,
      r.when.millisecondsSinceEpoch,
      r.offsetDays,
    );
    return idBase + (h.abs() % 2000000000);
  }

  /// Android：把未来最近的提醒交给系统按时弹出（应用不在前台也能收到）。
  /// 返回本次预约的条数；其它平台返回 0。
  static Future<int> schedule(SyncClient client, {DateTime? now}) async {
    if (!Platform.isAndroid) return 0;
    final t = now ?? DateTime.now();
    await _load();
    final future = [
      for (final r in plan(client.blocks, t))
        if (r.when.isAfter(t.add(const Duration(minutes: 1)))) r,
    ].take(maxScheduled).toList();
    final p = await _prefs();
    final previous = (p?.getStringList(_prefScheduled) ?? const <String>[])
        .map(int.tryParse)
        .whereType<int>()
        .toSet();
    final next = {for (final r in future) _stableId(r)};
    await Notifier.cancelReminders(previous.difference(next));
    var n = 0;
    for (final r in future) {
      final ok = await Notifier.scheduleReminder(
        id: _stableId(r),
        title: r.title,
        body: r.body,
        when: r.when,
        payload: r.blockId,
      );
      if (ok) {
        // 系统会按时弹出；之后应用在前台检查到它时不要再弹一次。
        _fired.add(keyOf(r));
        n++;
      }
    }
    await p?.setStringList(_prefScheduled, [for (final id in next) '$id']);
    await _save();
    return n;
  }

  static void forget() {
    _fired.clear();
    _loaded = true;
    _lastRun = null;
  }

  static DateTime? get lastRun => _lastRun;

  /// 仅用于测试：避免 id 计算被优化掉。
  static int debugId(ReminderInstant r) => min(_stableId(r), 0x7fffffff);
}
