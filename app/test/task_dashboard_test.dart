import 'package:flutter_test/flutter_test.dart';
import 'package:syncnotes/models/block.dart';
import 'package:syncnotes/sync/local_store.dart';
import 'package:syncnotes/sync/sync_client.dart';
import 'package:syncnotes/tasks/task_actions.dart';
import 'package:syncnotes/tasks/task_models.dart';
import 'package:syncnotes/tasks/task_queries.dart';

Block task(
  String id, {
  String title = '',
  String? parent,
  TaskData data = const TaskData(),
  int createdAt = 1,
  int updatedAt = 1,
  String kindRaw = 'task',
  BlockKind kind = BlockKind.task,
}) =>
    Block(
      id: id,
      kind: kind,
      kindRaw: kindRaw,
      title: title.isEmpty ? id : title,
      payload: data.toPayload(),
      parentId: parent,
      createdAt: createdAt,
      updatedAt: updatedAt,
    );

int day(int y, int m, int d, [int hh = 0, int mm = 0]) =>
    DateTime(y, m, d, hh, mm).millisecondsSinceEpoch;

void main() {
  test('kindRaw is preserved on upsert so unknown types are not rewritten', () {
    final b = Block.fromServer({
      'id': 'x',
      'kind': 'future_widget',
      'title': 't',
      'payload': {'is_task': true, 'status': 'todo'},
      'created_at': 1,
      'updated_at': 1,
      'created_by': 'd',
      'deleted': false,
      'seq': 1,
    });
    expect(b.kind, BlockKind.unknown);
    expect(b.kindRaw, 'future_widget');
    expect(b.wireKind, 'future_widget');
    expect(b.toUpsertMessage()['kind'], 'future_widget');
    expect(isTaskBlock(b), isTrue);
  });

  test('task kind round-trips through JSON', () {
    final b = task('a', data: const TaskData(priority: TaskPriority.high, notes: 'n'));
    final j = b.toJson();
    expect(j['kind'], 'task');
    final back = Block.fromJson(j);
    expect(back.kind, BlockKind.task);
    expect(taskDataOf(back).priority, TaskPriority.high);
    expect(taskDataOf(back).notes, 'n');
  });

  test('weighted progress uses custom weights and partial percent items', () {
    final t = task('root', data: TaskData(items: [
      const ProgressItem(id: 'a', title: '设计', weight: 70, kind: ProgressItemKind.check, done: true),
      const ProgressItem(id: 'b', title: '实现', weight: 30, kind: ProgressItemKind.percent, percent: 0.5),
    ]));
    expect(computeTaskProgress(t, {t.id: t}), closeTo(0.85, 0.0001));
  });

  test('equal mode ignores weights', () {
    final t = task('root', data: TaskData(
      progressMode: ProgressMode.equal,
      items: const [
        ProgressItem(id: 'a', title: '小', weight: 90, done: true),
        ProgressItem(id: 'b', title: '大', weight: 10, done: false),
      ],
    ));
    expect(computeTaskProgress(t, {t.id: t}), closeTo(0.5, 0.0001));
  });

  test('manual mode uses the slider value', () {
    final t = task('root', data: const TaskData(progressMode: ProgressMode.manual, manualProgress: 0.42));
    expect(computeTaskProgress(t, {t.id: t}), closeTo(0.42, 0.0001));
  });

  test('done tasks are always 100% and cancelled are 0%', () {
    final done = task('d', data: const TaskData(status: TaskStatus.done, manualProgress: 0.1, progressMode: ProgressMode.manual));
    final cancelled = task('c', data: const TaskData(status: TaskStatus.cancelled, progressMode: ProgressMode.manual, manualProgress: 0.8));
    expect(computeTaskProgress(done, {done.id: done}), 1);
    expect(computeTaskProgress(cancelled, {cancelled.id: cancelled}), 0);
  });

  test('subtask progress rolls up; cancelled children leave the denominator', () {
    final child = task('c', data: TaskData(items: const [
      ProgressItem(id: 'i', title: '一步', done: true),
      ProgressItem(id: 'j', title: '二步', done: false),
    ]));
    final cancelled = task('x', data: const TaskData(status: TaskStatus.cancelled));
    final parent = task('p', data: TaskData(items: [
      ProgressItem(id: 's1', title: '子', kind: ProgressItemKind.subtask, subtaskId: 'c', weight: 1),
      ProgressItem(id: 's2', title: '取消', kind: ProgressItemKind.subtask, subtaskId: 'x', weight: 1),
    ]));
    final byId = {parent.id: parent, child.id: child, cancelled.id: cancelled};
    // only the live child counts, at 50%
    expect(computeTaskProgress(parent, byId), closeTo(0.5, 0.0001));
  });

  test('unlisted child tasks are auto-included with weight 1', () {
    final child = task('c', parent: 'p', data: const TaskData(status: TaskStatus.done));
    final parent = task('p');
    expect(computeTaskProgress(parent, {parent.id: parent, child.id: child}), 1);
  });

  test('adding items can lower existing progress (scope change)', () {
    final before = task('p', data: TaskData(items: const [
      ProgressItem(id: 'a', title: '仅一项', done: true),
    ]));
    final after = task('p', data: TaskData(items: const [
      ProgressItem(id: 'a', title: '仅一项', done: true),
      ProgressItem(id: 'b', title: '新范围', done: false),
    ]));
    expect(computeTaskProgress(before, {before.id: before}), 1);
    expect(computeTaskProgress(after, {after.id: after}), closeTo(0.5, 0.0001));
  });

  test('all-day due date is overdue after the local day ends, not at midnight', () {
    final d = TaskData(dueAt: day(2026, 11, 28), allDay: true);
    expect(isOverdueAt(d, DateTime(2026, 11, 28, 18, 0)), isFalse);
    expect(isOverdueAt(d, DateTime(2026, 11, 29, 0, 0, 1)), isTrue);
  });

  test('today view includes flagged, due today, in-range, and overdue items', () {
    final now = DateTime(2026, 11, 28, 10);
    expect(isInToday(TaskData(flagged: true), now), isTrue);
    expect(isInToday(TaskData(dueAt: day(2026, 11, 28), allDay: true), now), isTrue);
    expect(isInToday(TaskData(dueAt: day(2026, 11, 20), allDay: true), now), isTrue);
    expect(
      isInToday(TaskData(startAt: day(2026, 11, 27), dueAt: day(2026, 11, 30), allDay: true), now),
      isTrue,
    );
    expect(isInToday(TaskData(dueAt: day(2026, 12, 1), allDay: true), now), isFalse);
    expect(isInToday(const TaskData(status: TaskStatus.done, flagged: true), now), isFalse);
  });

  test('upcoming is the next 7 days excluding today', () {
    final now = DateTime(2026, 11, 28, 10);
    expect(isUpcoming(TaskData(dueAt: day(2026, 11, 28)), now), isFalse);
    expect(isUpcoming(TaskData(dueAt: day(2026, 11, 29)), now), isTrue);
    expect(isUpcoming(TaskData(dueAt: day(2026, 12, 5)), now), isTrue);
    expect(isUpcoming(TaskData(dueAt: day(2026, 12, 6)), now), isFalse);
  });

  test('health marks overdue, at-risk (behind schedule), and on-track', () {
    final now = DateTime(2026, 11, 28, 12);
    final overdue = task('o', data: TaskData(dueAt: day(2026, 11, 20), allDay: true));
    expect(taskHealthOf(overdue, {overdue.id: overdue}, now: now), TaskHealth.overdue);

    // start 11-21, due 11-28, halfway through the window but 0% progress → at risk
    final behind = task(
      'b',
      createdAt: day(2026, 11, 21),
      data: TaskData(startAt: day(2026, 11, 21), dueAt: day(2026, 11, 28), allDay: true),
    );
    expect(taskHealthOf(behind, {behind.id: behind}, now: now), TaskHealth.atRisk);

    final onTrack = task(
      't',
      createdAt: day(2026, 11, 21),
      data: TaskData(
        startAt: day(2026, 11, 21),
        dueAt: day(2026, 12, 10),
        allDay: true,
        progressMode: ProgressMode.manual,
        manualProgress: 0.4,
        status: TaskStatus.inProgress,
      ),
    );
    expect(taskHealthOf(onTrack, {onTrack.id: onTrack}, now: now), TaskHealth.onTrack);
  });

  test('task depth is capped at 5 levels', () {
    final byId = <String, Block>{};
    Block? parent;
    for (var i = 0; i < 6; i++) {
      final b = task('t$i', parent: parent?.id);
      byId[b.id] = b;
      parent = b;
    }
    expect(taskDepth(byId['t0']!, byId), 0);
    expect(taskDepth(byId['t4']!, byId), 4);
    expect(canAddSubtask(byId['t3']!, byId), isTrue);
    expect(canAddSubtask(byId['t4']!, byId), isFalse);
  });

  test('subtask date warning when it falls outside the parent window', () {
    final parent = const TaskData(startAt: 100, dueAt: 200, allDay: false);
    expect(subtaskOutsideParent(const TaskData(startAt: 90, dueAt: 150, allDay: false), parent), isTrue);
    expect(subtaskOutsideParent(const TaskData(startAt: 120, dueAt: 180, allDay: false), parent), isFalse);
    expect(datesInverted(const TaskData(startAt: 200, dueAt: 100, allDay: false)), isTrue);
  });

  test('save, weighted items, auto-complete parent, and inbox hides subtasks', () {
    final sync = SyncClient(store: MemoryStore(), deviceId: 'pc');
    final parent = saveTask(sync, null, title: '发布 v1', data: const TaskData(priority: TaskPriority.urgent))!;
    upsertProgressItem(
      sync,
      sync.byId(parent.id)!,
      const ProgressItem(id: 'p1', title: '文案', weight: 25, done: true),
    );
    upsertProgressItem(
      sync,
      sync.byId(parent.id)!,
      const ProgressItem(id: 'p2', title: '构建', weight: 75, done: false),
    );
    final fresh = sync.byId(parent.id)!;
    expect(isTaskBlock(fresh), isTrue);
    expect(computeTaskProgress(fresh, taskIndexOf(sync)), closeTo(0.25, 0.0001));

    addSubtask(sync, sync.byId(parent.id)!, title: '打包安装包');
    expect(sync.childrenOf(null).where((b) => b.id != parent.id && isTaskBlock(b)), isEmpty);
    expect(sync.childrenOf(parent.id).map((b) => b.title), contains('打包安装包'));

    // finish remaining checklist and the auto-included subtask should still block auto-complete
    toggleProgressItem(sync, sync.byId(parent.id)!, 'p2', done: true);
    expect(taskDataOf(sync.byId(parent.id)!).status, isNot(TaskStatus.done));

    setTaskCompleted(sync, sync.childrenOf(parent.id).single, true);
    expect(taskDataOf(sync.byId(parent.id)!).status, TaskStatus.done);
    expect(taskDataOf(sync.byId(parent.id)!).completedAt, isNotNull);

    setTaskCompleted(sync, sync.byId(parent.id)!, false);
    expect(taskDataOf(sync.byId(parent.id)!).status, isNot(TaskStatus.done));
    expect(sync.byId(parent.id)!.toUpsertMessage()['kind'], 'task');
    sync.dispose();
  });

  test('dashboard stats and smart views', () {
    final sync = SyncClient(store: MemoryStore(), deviceId: 'pc');
    final now = DateTime(2026, 11, 28, 15);
    saveTask(
      sync,
      null,
      title: '逾期任务',
      data: TaskData(dueAt: day(2026, 11, 20), allDay: true, priority: TaskPriority.high),
    );
    saveTask(
      sync,
      null,
      title: '今天截止',
      data: TaskData(dueAt: day(2026, 11, 28), allDay: true, flagged: true),
    );
    saveTask(
      sync,
      null,
      title: '下周的事',
      data: TaskData(dueAt: day(2026, 12, 3), allDay: true),
    );
    saveTask(
      sync,
      null,
      title: '已做完',
      data: TaskData(status: TaskStatus.done, completedAt: day(2026, 11, 27), allDay: true),
    );
    saveTask(
      sync,
      null,
      title: '里程碑',
      data: const TaskData(milestone: true, status: TaskStatus.inProgress),
    );

    final stats = dashboardStats(sync, now: now);
    expect(stats.overdue, 1);
    expect(stats.today, greaterThanOrEqualTo(2)); // 逾期 + 今天截止
    expect(stats.completedThisWeek, 1);
    expect(stats.milestones, 1);
    expect(stats.active, 4);

    final overdue = tasksForView(sync, TaskSmartView.overdue, now: now);
    expect(overdue.map((b) => b.title), ['逾期任务']);
    final upcoming = tasksForView(sync, TaskSmartView.upcoming, now: now);
    expect(upcoming.map((b) => b.title), contains('下周的事'));
    expect(upcoming.map((b) => b.title), isNot(contains('今天截止')));
    final milestones = tasksForView(sync, TaskSmartView.milestones, now: now);
    expect(milestones.map((b) => b.title), ['里程碑']);
    sync.dispose();
  });

  test('old-client recovery: unknown kind plus is_task is still a task', () {
    final b = Block(
      id: 'old',
      kind: BlockKind.unknown,
      kindRaw: 'unknown',
      title: '救援',
      payload: const TaskData(priority: TaskPriority.medium).toPayload(),
      createdAt: 1,
      updatedAt: 1,
    );
    expect(isTaskBlock(b), isTrue);
    final sync = SyncClient(store: MemoryStore(), deviceId: 'pc');
    // inject via create then overwrite kind? use update after create
    final created = saveTask(sync, null, title: '救援', data: const TaskData())!;
    // simulate old client rewriting kind
    final spoofed = created.copyWith(kind: BlockKind.unknown, kindRaw: 'unknown');
    expect(isTaskBlock(spoofed), isTrue);
    final saved = saveTask(sync, spoofed, title: spoofed.title, data: taskDataOf(spoofed))!;
    expect(saved.kind, BlockKind.task);
    expect(saved.wireKind, 'task');
    sync.dispose();
  });
}
