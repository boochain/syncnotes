import '../models/block.dart';
import '../sync/sync_client.dart';
import 'task_models.dart';

Map<String, Block> taskIndexOf(SyncClient sync) => {for (final b in sync.blocks) b.id: b};

/// 父级不是任务的任务（可挂在收件箱根或文件夹下）。
bool isRootTask(Block b, Map<String, Block> byId) {
  if (!isLiveTask(b)) return false;
  final pid = b.parentId;
  if (pid == null) return true;
  final p = byId[pid];
  return p == null || !isTaskBlock(p);
}

List<Block> rootTasksOf(SyncClient sync) {
  final byId = taskIndexOf(sync);
  return [for (final b in sync.blocks) if (isRootTask(b, byId)) b];
}

List<Block> allLiveTasksOf(SyncClient sync) => [for (final b in sync.blocks) if (isLiveTask(b)) b];

class TaskDashboardStats {
  final int overdue;
  final int today;
  final int inProgress;
  final int atRisk;
  final int completedThisWeek;
  final int active;
  final int milestones;
  final double workProgress;

  const TaskDashboardStats({
    required this.overdue,
    required this.today,
    required this.inProgress,
    required this.atRisk,
    required this.completedThisWeek,
    required this.active,
    required this.milestones,
    required this.workProgress,
  });
}

TaskDashboardStats dashboardStats(SyncClient sync, {DateTime? now}) {
  final t = now ?? DateTime.now();
  final weekStart = DateTime(t.year, t.month, t.day).subtract(Duration(days: t.weekday - 1));
  final byId = taskIndexOf(sync);
  final roots = rootTasksOf(sync);
  var overdue = 0, today = 0, inProgress = 0, atRisk = 0, completedThisWeek = 0, active = 0, milestones = 0;
  var progressSum = 0.0, progressCount = 0;
  for (final b in roots) {
    final d = taskDataOf(b);
    if (d.status == TaskStatus.cancelled) continue;
    if (d.milestone && d.status != TaskStatus.done) milestones++;
    if (d.status == TaskStatus.done) {
      final doneAt = dateOfMillis(d.completedAt) ?? DateTime.fromMillisecondsSinceEpoch(b.updatedAt);
      if (!doneAt.isBefore(weekStart)) completedThisWeek++;
      continue;
    }
    active++;
    progressSum += computeTaskProgress(b, byId);
    progressCount++;
    final health = taskHealthOf(b, byId, now: t);
    if (health == TaskHealth.overdue) overdue++;
    if (isInToday(d, t)) today++;
    if (health == TaskHealth.atRisk) atRisk++;
    if (d.status == TaskStatus.inProgress || health == TaskHealth.inProgress || health == TaskHealth.onTrack) {
      inProgress++;
    }
  }
  return TaskDashboardStats(
    overdue: overdue,
    today: today,
    inProgress: inProgress,
    atRisk: atRisk,
    completedThisWeek: completedThisWeek,
    active: active,
    milestones: milestones,
    workProgress: progressCount == 0 ? 0 : progressSum / progressCount,
  );
}

int overdueRootCount(SyncClient sync, {DateTime? now}) {
  final t = now ?? DateTime.now();
  var n = 0;
  for (final b in rootTasksOf(sync)) {
    if (isOverdueAt(taskDataOf(b), t)) n++;
  }
  return n;
}

bool matchesSmartView(Block b, TaskSmartView view, Map<String, Block> byId, DateTime now) {
  final d = taskDataOf(b);
  switch (view) {
    case TaskSmartView.overview:
      return isRootTask(b, byId) && d.status != TaskStatus.cancelled;
    case TaskSmartView.active:
      return isRootTask(b, byId) && d.status != TaskStatus.done && d.status != TaskStatus.cancelled;
    case TaskSmartView.completed:
      return isRootTask(b, byId) && d.status == TaskStatus.done;
    case TaskSmartView.milestones:
      return d.milestone && d.status != TaskStatus.cancelled;
    case TaskSmartView.today:
      return isInToday(d, now);
    case TaskSmartView.upcoming:
      return isUpcoming(d, now);
    case TaskSmartView.overdue:
      return isOverdueAt(d, now);
    case TaskSmartView.inProgress:
      return d.status != TaskStatus.done &&
          d.status != TaskStatus.cancelled &&
          (d.status == TaskStatus.inProgress || computeTaskProgress(b, byId) > 0);
    case TaskSmartView.atRisk:
      final h = taskHealthOf(b, byId, now: now);
      return h == TaskHealth.atRisk || h == TaskHealth.overdue;
  }
}

enum TaskSort { priority, due, progress, updated, title }

String taskSortLabel(TaskSort s) => switch (s) {
      TaskSort.priority => '优先级',
      TaskSort.due => '截止时间',
      TaskSort.progress => '进度',
      TaskSort.updated => '最近更新',
      TaskSort.title => '标题',
    };

int compareTasks(Block a, Block b, TaskSort sort, Map<String, Block> byId) {
  final da = taskDataOf(a);
  final db = taskDataOf(b);
  final aDone = da.status == TaskStatus.done;
  final bDone = db.status == TaskStatus.done;
  if (aDone != bDone) return aDone ? 1 : -1;
  int c;
  switch (sort) {
    case TaskSort.priority:
      c = taskPriorityWire(db.priority).compareTo(taskPriorityWire(da.priority));
      if (c != 0) return c;
      c = _dueCmp(da, db);
    case TaskSort.due:
      c = _dueCmp(da, db);
    case TaskSort.progress:
      c = computeTaskProgress(a, byId).compareTo(computeTaskProgress(b, byId));
    case TaskSort.updated:
      c = b.updatedAt.compareTo(a.updatedAt);
    case TaskSort.title:
      c = a.title.toLowerCase().compareTo(b.title.toLowerCase());
  }
  if (c != 0) return c;
  return a.createdAt.compareTo(b.createdAt);
}

int _dueCmp(TaskData a, TaskData b) {
  final ad = a.dueAt;
  final bd = b.dueAt;
  if (ad == null && bd == null) return 0;
  if (ad == null) return 1;
  if (bd == null) return -1;
  return ad.compareTo(bd);
}

List<Block> tasksForView(
  SyncClient sync,
  TaskSmartView view, {
  TaskSort sort = TaskSort.priority,
  DateTime? now,
  String query = '',
}) {
  final t = now ?? DateTime.now();
  final byId = taskIndexOf(sync);
  final q = query.trim().toLowerCase();
  final src = (view == TaskSmartView.overview ||
          view == TaskSmartView.active ||
          view == TaskSmartView.completed)
      ? rootTasksOf(sync)
      : allLiveTasksOf(sync);
  final items = [
    for (final b in src)
      if (matchesSmartView(b, view, byId, t))
        if (q.isEmpty ||
            b.title.toLowerCase().contains(q) ||
            taskDataOf(b).notes.toLowerCase().contains(q))
          b,
  ];
  items.sort((a, b) => compareTasks(a, b, sort, byId));
  return items;
}

String? parentTaskTitle(Block b, Map<String, Block> byId) {
  final pid = b.parentId;
  if (pid == null) return null;
  final p = byId[pid];
  if (p == null || !isTaskBlock(p)) return null;
  return p.title;
}
