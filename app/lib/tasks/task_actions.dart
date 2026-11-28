import 'package:uuid/uuid.dart';

import '../models/block.dart';
import '../sync/sync_client.dart';
import 'task_models.dart';
import 'task_queries.dart';

const _uuid = Uuid();

String newProgressItemId() => _uuid.v4();

Block? saveTask(SyncClient sync, Block? existing,
    {required String title, required TaskData data, String? parentId, bool moveToRoot = false}) {
  final payload = data.toPayload(existing?.payload ?? const {});
  if (existing == null) {
    return sync.create(
      kind: BlockKind.task,
      title: title.trim().isEmpty ? '未命名任务' : title.trim(),
      payload: payload,
      parentId: parentId,
    );
  }
  return sync.update(
    existing.id,
    title: title.trim().isEmpty ? '未命名任务' : title.trim(),
    payload: payload,
    parentId: parentId,
    moveToRoot: moveToRoot,
    kind: BlockKind.task,
    kindName: 'task',
  );
}

Block? setTaskCompleted(SyncClient sync, Block block, bool completed, {int? completedAt}) {
  if (!isTaskBlock(block)) return null;
  var data = taskDataOf(block);
  final now = DateTime.now().millisecondsSinceEpoch;
  if (completed) {
    data = data.copyWith(
      status: TaskStatus.done,
      completedAt: completedAt ?? data.completedAt ?? now,
    );
  } else {
    data = data.copyWith(
      status: data.progressMode == ProgressMode.manual && data.manualProgress > 0
          ? TaskStatus.inProgress
          : TaskStatus.todo,
      clearCompleted: true,
    );
  }
  final updated = saveTask(sync, block, title: block.title, data: data, parentId: block.parentId);
  if (completed && data.autoCompleteChildren) {
    _completeDescendants(sync, block.id, completedAt ?? now);
  }
  if (completed) {
    maybeAutoCompleteAncestors(sync, block.parentId);
  }
  return updated;
}

Block? setTaskStatus(SyncClient sync, Block block, TaskStatus status) {
  if (status == TaskStatus.done) return setTaskCompleted(sync, block, true);
  var data = taskDataOf(block).copyWith(
    status: status,
    clearCompleted: status != TaskStatus.done,
  );
  final updated = saveTask(sync, block, title: block.title, data: data, parentId: block.parentId);
  return updated;
}

void _completeDescendants(SyncClient sync, String parentId, int completedAt) {
  final byId = taskIndexOf(sync);
  for (final child in taskChildrenOf(parentId, byId)) {
    if (taskDataOf(child).status == TaskStatus.cancelled) continue;
    if (taskDataOf(child).status != TaskStatus.done) {
      setTaskCompleted(sync, child, true, completedAt: completedAt);
    }
  }
}

/// 子项全部完成后，沿祖先链把开启了自动完成的父任务标为完成。
void maybeAutoCompleteAncestors(SyncClient sync, String? parentId) {
  final seen = <String>{};
  var pid = parentId;
  while (pid != null && seen.add(pid)) {
    final parent = sync.byId(pid);
    if (parent == null || !isLiveTask(parent)) return;
    final data = taskDataOf(parent);
    if (!data.autoCompleteParent || data.status == TaskStatus.done) return;
    final byId = taskIndexOf(sync);
    if (!allProgressComplete(parent, byId)) return;
    setTaskCompleted(sync, parent, true);
    pid = parent.parentId;
  }
}

Block? toggleProgressItem(SyncClient sync, Block task, String itemId, {bool? done, double? percent}) {
  var data = taskDataOf(task);
  final now = DateTime.now().millisecondsSinceEpoch;
  final items = [
    for (final i in data.items)
      if (i.id == itemId)
        i.copyWith(
          done: done ?? (percent != null ? percent >= 0.999 : !i.done),
          percent: percent ?? (done == true || (done == null && !i.done) ? 1 : (done == false ? 0 : i.percent)),
          completedAt: (done ?? !i.done) ? now : null,
          clearCompleted: !(done ?? !i.done),
        )
      else
        i,
  ];
  data = data.copyWith(items: items);
  if (data.status == TaskStatus.todo) data = data.copyWith(status: TaskStatus.inProgress);
  final updated = saveTask(sync, task, title: task.title, data: data, parentId: task.parentId);
  if (updated != null) maybeAutoCompleteAncestors(sync, updated.id);
  return updated;
}

Block? upsertProgressItem(SyncClient sync, Block task, ProgressItem item) {
  var data = taskDataOf(task);
  final items = [...data.items];
  final idx = items.indexWhere((e) => e.id == item.id);
  if (idx >= 0) {
    items[idx] = item;
  } else {
    items.add(item);
  }
  data = data.copyWith(items: items);
  return saveTask(sync, task, title: task.title, data: data, parentId: task.parentId);
}

Block? removeProgressItem(SyncClient sync, Block task, String itemId) {
  final data = taskDataOf(task).copyWith(items: [for (final i in taskDataOf(task).items) if (i.id != itemId) i]);
  return saveTask(sync, task, title: task.title, data: data, parentId: task.parentId);
}

Block? reorderProgressItems(SyncClient sync, Block task, int from, int to) {
  final items = [...taskDataOf(task).items];
  if (from < 0 || from >= items.length || to < 0 || to >= items.length) return task;
  final item = items.removeAt(from);
  items.insert(to, item);
  return saveTask(sync, task, title: task.title, data: taskDataOf(task).copyWith(items: items), parentId: task.parentId);
}

/// 新建子任务，并在父任务进度组成里加一项引用。
Block? addSubtask(SyncClient sync, Block parent, {String title = '子任务', TaskData? data}) {
  final byId = taskIndexOf(sync);
  if (!canAddSubtask(parent, byId)) return null;
  final child = saveTask(sync, null, title: title, data: data ?? const TaskData(), parentId: parent.id);
  if (child == null) return null;
  final item = ProgressItem(
    id: newProgressItemId(),
    title: child.title,
    kind: ProgressItemKind.subtask,
    subtaskId: child.id,
  );
  upsertProgressItem(sync, sync.byId(parent.id) ?? parent, item);
  return child;
}
