import '../models/block.dart';

/// 任务块最多 5 层（根为第 0 层，最深第 4 层），与滴答清单一致。
const int maxTaskDepth = 4;

enum TaskStatus { todo, inProgress, done, cancelled }

enum TaskPriority { none, low, medium, high, urgent }

enum ProgressMode { weighted, equal, manual }

enum ProgressItemKind { check, percent, subtask }

enum TaskHealth { completed, cancelled, overdue, atRisk, onTrack, notStarted, inProgress }

enum TaskSmartView { overview, today, upcoming, overdue, inProgress, atRisk, active, completed, milestones }

bool isTaskBlock(Block b) =>
    b.kind == BlockKind.task || b.kindRaw == 'task' || b.payload['is_task'] == true;

String taskStatusWire(TaskStatus s) => switch (s) {
      TaskStatus.todo => 'todo',
      TaskStatus.inProgress => 'in_progress',
      TaskStatus.done => 'done',
      TaskStatus.cancelled => 'cancelled',
    };

TaskStatus taskStatusFrom(Object? v) => switch (v) {
      'in_progress' => TaskStatus.inProgress,
      'done' => TaskStatus.done,
      'cancelled' => TaskStatus.cancelled,
      _ => TaskStatus.todo,
    };

String progressModeWire(ProgressMode m) => switch (m) {
      ProgressMode.weighted => 'weighted',
      ProgressMode.equal => 'equal',
      ProgressMode.manual => 'manual',
    };

ProgressMode progressModeFrom(Object? v) => switch (v) {
      'equal' => ProgressMode.equal,
      'manual' => ProgressMode.manual,
      _ => ProgressMode.weighted,
    };

String progressItemKindWire(ProgressItemKind k) => switch (k) {
      ProgressItemKind.check => 'check',
      ProgressItemKind.percent => 'percent',
      ProgressItemKind.subtask => 'subtask',
    };

ProgressItemKind progressItemKindFrom(Object? v) => switch (v) {
      'percent' => ProgressItemKind.percent,
      'subtask' => ProgressItemKind.subtask,
      _ => ProgressItemKind.check,
    };

TaskPriority taskPriorityFrom(Object? v) {
  if (v is num) {
    final n = v.toInt();
    if (n <= 0) return TaskPriority.none;
    if (n == 1) return TaskPriority.low;
    if (n == 2) return TaskPriority.medium;
    if (n == 3) return TaskPriority.high;
    return TaskPriority.urgent;
  }
  return TaskPriority.none;
}

int taskPriorityWire(TaskPriority p) => p.index;

String taskPriorityLabel(TaskPriority p) => switch (p) {
      TaskPriority.none => '无',
      TaskPriority.low => '低',
      TaskPriority.medium => '中',
      TaskPriority.high => '高',
      TaskPriority.urgent => '紧急',
    };

String taskStatusLabel(TaskStatus s) => switch (s) {
      TaskStatus.todo => '未开始',
      TaskStatus.inProgress => '进行中',
      TaskStatus.done => '已完成',
      TaskStatus.cancelled => '已取消',
    };

String taskHealthLabel(TaskHealth h) => switch (h) {
      TaskHealth.completed => '已完成',
      TaskHealth.cancelled => '已取消',
      TaskHealth.overdue => '已逾期',
      TaskHealth.atRisk => '有风险',
      TaskHealth.onTrack => '进度正常',
      TaskHealth.notStarted => '未开始',
      TaskHealth.inProgress => '进行中',
    };

String taskSmartViewLabel(TaskSmartView v) => switch (v) {
      TaskSmartView.overview => '总览',
      TaskSmartView.today => '今天',
      TaskSmartView.upcoming => '即将',
      TaskSmartView.overdue => '逾期',
      TaskSmartView.inProgress => '进行中',
      TaskSmartView.atRisk => '有风险',
      TaskSmartView.active => '全部未完成',
      TaskSmartView.completed => '已完成',
      TaskSmartView.milestones => '里程碑',
    };

class ProgressItem {
  final String id;
  final String title;
  final double weight;
  final ProgressItemKind kind;
  final bool done;
  final double percent;
  final String? subtaskId;
  final int? startAt;
  final int? dueAt;
  final int? completedAt;

  const ProgressItem({
    required this.id,
    required this.title,
    this.weight = 1,
    this.kind = ProgressItemKind.check,
    this.done = false,
    this.percent = 0,
    this.subtaskId,
    this.startAt,
    this.dueAt,
    this.completedAt,
  });

  ProgressItem copyWith({
    String? title,
    double? weight,
    ProgressItemKind? kind,
    bool? done,
    double? percent,
    String? subtaskId,
    bool clearSubtask = false,
    int? startAt,
    int? dueAt,
    int? completedAt,
    bool clearStart = false,
    bool clearDue = false,
    bool clearCompleted = false,
  }) =>
      ProgressItem(
        id: id,
        title: title ?? this.title,
        weight: weight ?? this.weight,
        kind: kind ?? this.kind,
        done: done ?? this.done,
        percent: percent ?? this.percent,
        subtaskId: clearSubtask ? null : (subtaskId ?? this.subtaskId),
        startAt: clearStart ? null : (startAt ?? this.startAt),
        dueAt: clearDue ? null : (dueAt ?? this.dueAt),
        completedAt: clearCompleted ? null : (completedAt ?? this.completedAt),
      );

  factory ProgressItem.fromJson(Map<String, dynamic> j) => ProgressItem(
        id: (j['id'] ?? '') as String,
        title: (j['title'] ?? '') as String,
        weight: _num(j['weight'], 1),
        kind: progressItemKindFrom(j['kind']),
        done: j['done'] == true,
        percent: _num(j['percent'], 0),
        subtaskId: j['subtask_id'] as String?,
        startAt: _intOrNull(j['start_at']),
        dueAt: _intOrNull(j['due_at']),
        completedAt: _intOrNull(j['completed_at']),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'weight': weight,
        'kind': progressItemKindWire(kind),
        'done': done,
        'percent': percent,
        'subtask_id': subtaskId,
        'start_at': startAt,
        'due_at': dueAt,
        'completed_at': completedAt,
      };
}

class TaskData {
  final int schema;
  final TaskStatus status;
  final TaskPriority priority;
  final int? startAt;
  final int? dueAt;
  final int? completedAt;
  final bool allDay;
  final ProgressMode progressMode;
  final double manualProgress;
  final bool autoCompleteParent;
  final bool autoCompleteChildren;
  final String notes;
  final bool milestone;
  final bool flagged;
  final List<ProgressItem> items;

  const TaskData({
    this.schema = 1,
    this.status = TaskStatus.todo,
    this.priority = TaskPriority.none,
    this.startAt,
    this.dueAt,
    this.completedAt,
    this.allDay = true,
    this.progressMode = ProgressMode.weighted,
    this.manualProgress = 0,
    this.autoCompleteParent = true,
    this.autoCompleteChildren = false,
    this.notes = '',
    this.milestone = false,
    this.flagged = false,
    this.items = const [],
  });

  TaskData copyWith({
    TaskStatus? status,
    TaskPriority? priority,
    int? startAt,
    int? dueAt,
    int? completedAt,
    bool clearStart = false,
    bool clearDue = false,
    bool clearCompleted = false,
    bool? allDay,
    ProgressMode? progressMode,
    double? manualProgress,
    bool? autoCompleteParent,
    bool? autoCompleteChildren,
    String? notes,
    bool? milestone,
    bool? flagged,
    List<ProgressItem>? items,
  }) =>
      TaskData(
        schema: schema,
        status: status ?? this.status,
        priority: priority ?? this.priority,
        startAt: clearStart ? null : (startAt ?? this.startAt),
        dueAt: clearDue ? null : (dueAt ?? this.dueAt),
        completedAt: clearCompleted ? null : (completedAt ?? this.completedAt),
        allDay: allDay ?? this.allDay,
        progressMode: progressMode ?? this.progressMode,
        manualProgress: manualProgress ?? this.manualProgress,
        autoCompleteParent: autoCompleteParent ?? this.autoCompleteParent,
        autoCompleteChildren: autoCompleteChildren ?? this.autoCompleteChildren,
        notes: notes ?? this.notes,
        milestone: milestone ?? this.milestone,
        flagged: flagged ?? this.flagged,
        items: items ?? this.items,
      );

  factory TaskData.fromPayload(Map<String, dynamic> p) {
    final rawItems = p['progress_items'];
    final items = <ProgressItem>[];
    if (rawItems is List) {
      for (final e in rawItems) {
        if (e is Map) items.add(ProgressItem.fromJson(Map<String, dynamic>.from(e)));
      }
    }
    var status = taskStatusFrom(p['status']);
    if (p['completed'] == true && status != TaskStatus.cancelled) status = TaskStatus.done;
    return TaskData(
      schema: p['schema'] is num ? (p['schema'] as num).toInt() : 1,
      status: status,
      priority: taskPriorityFrom(p['priority']),
      startAt: _intOrNull(p['start_at']),
      dueAt: _intOrNull(p['due_at']),
      completedAt: _intOrNull(p['completed_at']),
      allDay: p['all_day'] != false,
      progressMode: progressModeFrom(p['progress_mode']),
      manualProgress: _num(p['manual_progress'], 0),
      autoCompleteParent: p['auto_complete_parent'] != false,
      autoCompleteChildren: p['auto_complete_children'] == true,
      notes: (p['notes'] ?? '') as String,
      milestone: p['milestone'] == true,
      flagged: p['flagged'] == true,
      items: items,
    );
  }

  factory TaskData.fromBlock(Block b) => TaskData.fromPayload(b.payload);

  /// 写回 payload 时保留与任务无关的键，并带上收件箱兼容字段。
  Map<String, dynamic> toPayload([Map<String, dynamic> existing = const {}]) {
    final next = Map<String, dynamic>.from(existing);
    next['schema'] = schema;
    next['is_task'] = true;
    next['status'] = taskStatusWire(status);
    next['priority'] = taskPriorityWire(priority);
    next['start_at'] = startAt;
    next['due_at'] = dueAt;
    next['completed_at'] = completedAt;
    next['all_day'] = allDay;
    next['progress_mode'] = progressModeWire(progressMode);
    next['manual_progress'] = manualProgress;
    next['auto_complete_parent'] = autoCompleteParent;
    next['auto_complete_children'] = autoCompleteChildren;
    next['notes'] = notes;
    next['milestone'] = milestone;
    next['flagged'] = flagged;
    next['progress_items'] = [for (final i in items) i.toJson()];
    if (status == TaskStatus.done) {
      next['completed'] = true;
      if (completedAt != null) next['completed_at'] = completedAt;
    } else {
      next.remove('completed');
    }
    return next;
  }
}

TaskData taskDataOf(Block b) => TaskData.fromBlock(b);

bool isLiveTask(Block b) => isTaskBlock(b) && !b.deleted && b.deletedAt == null;

List<Block> taskChildrenOf(String parentId, Map<String, Block> byId) {
  final out = <Block>[];
  for (final b in byId.values) {
    if (b.parentId == parentId && isLiveTask(b)) out.add(b);
  }
  return out;
}

/// 从该任务向上数，经过多少个任务祖先。根任务为 0。
int taskDepth(Block task, Map<String, Block> byId) {
  var d = 0;
  var cur = task;
  final seen = <String>{};
  while (true) {
    final pid = cur.parentId;
    if (pid == null || !seen.add(pid)) return d;
    final p = byId[pid];
    if (p == null || !isTaskBlock(p)) return d;
    d++;
    cur = p;
  }
}

bool canAddSubtask(Block parent, Map<String, Block> byId) => taskDepth(parent, byId) < maxTaskDepth;

double computeTaskProgress(Block task, Map<String, Block> byId, {Set<String>? visiting}) {
  final data = taskDataOf(task);
  if (data.status == TaskStatus.done) return 1;
  if (data.status == TaskStatus.cancelled) return 0;
  if (data.progressMode == ProgressMode.manual) {
    final m = data.manualProgress;
    return m.isFinite ? m.clamp(0, 1).toDouble() : 0;
  }
  final seen = {...?visiting, task.id};
  final items = [...data.items];
  final listed = <String>{
    for (final i in items)
      if (i.kind == ProgressItemKind.subtask && i.subtaskId != null) i.subtaskId!,
  };
  for (final child in taskChildrenOf(task.id, byId)) {
    if (!listed.contains(child.id)) {
      items.add(ProgressItem(
        id: 'auto-${child.id}',
        title: child.title,
        kind: ProgressItemKind.subtask,
        subtaskId: child.id,
      ));
    }
  }
  var numerator = 0.0;
  var den = 0.0;
  for (final item in items) {
    final w = data.progressMode == ProgressMode.equal ? 1.0 : item.weight;
    if (!w.isFinite || w <= 0) continue; // 同步来的脏数据（NaN/Infinity）不能把整体进度变成 NaN
    switch (item.kind) {
      case ProgressItemKind.subtask:
        final id = item.subtaskId;
        if (id == null) continue;
        final child = byId[id];
        if (child == null || !isLiveTask(child)) continue;
        if (taskDataOf(child).status == TaskStatus.cancelled) continue;
        if (seen.contains(child.id)) continue;
        den += w;
        numerator += w * computeTaskProgress(child, byId, visiting: seen);
      case ProgressItemKind.percent:
        den += w;
        numerator += w * item.percent.clamp(0, 1);
      case ProgressItemKind.check:
        den += w;
        numerator += w * (item.done ? 1 : 0);
    }
  }
  if (den <= 0) return 0;
  return (numerator / den).clamp(0, 1);
}

/// 组成项是否都已完成（取消的子任务排除）。没有组成项和子任务时返回 false。
bool allProgressComplete(Block task, Map<String, Block> byId) {
  final data = taskDataOf(task);
  if (data.progressMode == ProgressMode.manual) {
    return data.manualProgress >= 0.999;
  }
  var counted = 0;
  bool itemDone(ProgressItem item) {
    switch (item.kind) {
      case ProgressItemKind.check:
        counted++;
        return item.done;
      case ProgressItemKind.percent:
        counted++;
        return item.percent >= 0.999;
      case ProgressItemKind.subtask:
        final child = item.subtaskId == null ? null : byId[item.subtaskId];
        if (child == null || !isLiveTask(child)) return true;
        if (taskDataOf(child).status == TaskStatus.cancelled) return true;
        counted++;
        return computeTaskProgress(child, byId, visiting: {task.id}) >= 0.999;
    }
  }

  for (final item in data.items) {
    if (!itemDone(item)) return false;
  }
  final listed = {
    for (final i in data.items)
      if (i.kind == ProgressItemKind.subtask && i.subtaskId != null) i.subtaskId!,
  };
  for (final child in taskChildrenOf(task.id, byId)) {
    if (listed.contains(child.id)) continue;
    if (taskDataOf(child).status == TaskStatus.cancelled) continue;
    counted++;
    if (computeTaskProgress(child, byId, visiting: {task.id}) < 0.999) return false;
  }
  return counted > 0;
}

DateTime? dateOfMillis(int? ms) => ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);

DateTime? effectiveDueEnd(TaskData d) {
  final due = dateOfMillis(d.dueAt);
  if (due == null) return null;
  if (!d.allDay) return due;
  return DateTime(due.year, due.month, due.day, 23, 59, 59, 999);
}

DateTime? effectiveStart(TaskData d) {
  final start = dateOfMillis(d.startAt);
  if (start == null) return null;
  if (!d.allDay) return start;
  return DateTime(start.year, start.month, start.day);
}

bool isOverdueAt(TaskData d, DateTime now) {
  if (d.status == TaskStatus.done || d.status == TaskStatus.cancelled) return false;
  final end = effectiveDueEnd(d);
  return end != null && now.isAfter(end);
}

/// 按起止时间（没有开始则用创建时间）线性预估应完成的比例。没有截止则无法预估。
double? expectedProgress(TaskData d, DateTime now, {required int createdAt}) {
  final end = effectiveDueEnd(d);
  if (end == null) return null;
  var start = effectiveStart(d) ?? DateTime.fromMillisecondsSinceEpoch(createdAt);
  if (d.allDay && d.startAt == null) {
    start = DateTime(start.year, start.month, start.day);
  }
  if (!end.isAfter(start)) return now.isAfter(end) ? 1.0 : 0.0;
  if (now.isBefore(start)) return 0;
  if (!now.isBefore(end)) return 1;
  return now.difference(start).inMilliseconds / end.difference(start).inMilliseconds;
}

TaskHealth taskHealthOf(Block task, Map<String, Block> byId, {DateTime? now}) {
  final t = now ?? DateTime.now();
  final data = taskDataOf(task);
  if (data.status == TaskStatus.done) return TaskHealth.completed;
  if (data.status == TaskStatus.cancelled) return TaskHealth.cancelled;
  if (isOverdueAt(data, t)) return TaskHealth.overdue;
  final progress = computeTaskProgress(task, byId);
  final due = effectiveDueEnd(data);
  if (due != null && !due.isBefore(t)) {
    final hours = due.difference(t).inHours;
    if (hours <= 48 && progress < 0.7) return TaskHealth.atRisk;
  }
  final expected = expectedProgress(data, t, createdAt: task.createdAt);
  if (expected != null && expected - progress >= 0.25) return TaskHealth.atRisk;
  final start = effectiveStart(data);
  if (start != null && !start.isAfter(t) && progress <= 0 && due != null && due.difference(t).inDays <= 7) {
    return TaskHealth.atRisk;
  }
  if (expected != null && progress >= (expected - 0.1) && (progress > 0 || expected <= 0.1)) {
    return TaskHealth.onTrack;
  }
  if (data.status == TaskStatus.inProgress || progress > 0) return TaskHealth.inProgress;
  return TaskHealth.notStarted;
}

bool isSameLocalDay(DateTime a, DateTime b) => a.year == b.year && a.month == b.month && a.day == b.day;

bool isDueOnDay(TaskData d, DateTime day) {
  final due = dateOfMillis(d.dueAt);
  if (due == null) return false;
  return isSameLocalDay(due, day);
}

/// 今天视图：今天到期、已开始且尚未过截止、旗标，以及逾期。
bool isInToday(TaskData d, DateTime now) {
  if (d.status == TaskStatus.done || d.status == TaskStatus.cancelled) return false;
  if (d.flagged) return true;
  if (isOverdueAt(d, now)) return true;
  if (isDueOnDay(d, now)) return true;
  final start = effectiveStart(d);
  final due = effectiveDueEnd(d);
  if (start != null && !start.isAfter(now) && (due == null || !now.isAfter(due))) return true;
  return false;
}

bool isUpcoming(TaskData d, DateTime now, {int days = 7}) {
  if (d.status == TaskStatus.done || d.status == TaskStatus.cancelled) return false;
  if (isOverdueAt(d, now) || isDueOnDay(d, now)) return false;
  final due = dateOfMillis(d.dueAt);
  if (due == null) return false;
  final startOfToday = DateTime(now.year, now.month, now.day);
  final lastDay = DateTime(startOfToday.year, startOfToday.month, startOfToday.day + days);
  final dueDay = DateTime(due.year, due.month, due.day);
  return dueDay.isAfter(startOfToday) && !dueDay.isAfter(lastDay);
}

String formatTaskDate(int? ms, {required bool allDay}) {
  if (ms == null) return '';
  final t = DateTime.fromMillisecondsSinceEpoch(ms);
  final d = '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';
  if (allDay) return d;
  return '$d ${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
}

String formatProgressPct(double p) {
  final n = (p * 100).round();
  return '$n%';
}

/// 开始晚于截止。
bool datesInverted(TaskData d) {
  if (d.startAt == null || d.dueAt == null) return false;
  if (d.allDay) {
    final s = effectiveStart(d)!;
    final e = DateTime.fromMillisecondsSinceEpoch(d.dueAt!);
    final dueDay = DateTime(e.year, e.month, e.day);
    return s.isAfter(dueDay);
  }
  return d.startAt! > d.dueAt!;
}

/// 子任务时间窗明显落在父任务之外（只比较已填写的一端）。
bool subtaskOutsideParent(TaskData child, TaskData parent) {
  if (child.startAt != null && parent.startAt != null && child.startAt! < parent.startAt!) return true;
  if (child.dueAt != null && parent.dueAt != null && child.dueAt! > parent.dueAt!) return true;
  return false;
}

double _num(Object? v, double fallback) {
  if (v is num) return v.toDouble();
  return fallback;
}

int? _intOrNull(Object? v) {
  if (v == null) return null;
  if (v is int) return v;
  if (v is num) return v.toInt();
  return null;
}
