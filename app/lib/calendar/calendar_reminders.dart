import 'dart:math';

import '../models/block.dart';
import '../platform/notifications.dart';
import '../sync/sync_client.dart';
import 'calendar_item.dart';

/// 日历提醒：应用回到前台或数据变化时重算未来 90 天的提醒。
///
/// 到期或刚过点的条目会立刻弹出通知；更远的提醒在支持调度的平台上预约。
/// Android 使用非精确闹钟，不申请 SCHEDULE_EXACT_ALARM。
class CalendarReminders {
  CalendarReminders._();

  static const horizonDays = 90;
  static const channelId = 'syncnotes_calendar';
  static const idBase = 71000;
  static DateTime? _lastRun;
  static final Set<String> _fired = {};

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
    final items = plan(client.blocks, t);
    var n = 0;
    final showFn = show ?? _defaultShow;
    for (final r in items) {
      // 到期前 1 分钟到过后 2 小时内补发一次，避免进程被杀后漏掉。
      if (r.when.isAfter(t.add(const Duration(minutes: 1)))) continue;
      if (r.when.isBefore(t.subtract(const Duration(hours: 2)))) continue;
      final key = '${r.blockId}@${r.when.toIso8601String()}@${r.offsetDays}';
      if (!_fired.add(key)) continue;
      await showFn(r);
      n++;
    }
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

  static void forget() {
    _fired.clear();
    _lastRun = null;
  }

  static DateTime? get lastRun => _lastRun;

  /// 仅用于测试：避免 id 计算被优化掉。
  static int debugId(ReminderInstant r) => min(_stableId(r), 0x7fffffff);
}
