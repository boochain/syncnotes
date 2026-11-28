import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../models/block.dart';
import '../sync/sync_client.dart';
import '../tasks/task_actions.dart';
import '../tasks/task_models.dart';
import '../tasks/task_queries.dart';
import 'ds.dart';
import 'glass.dart';
import 'task_widgets.dart';

/// 任务详情：重要程度、起止/完成时间、自定义加权进度项、子任务。
class TaskEditorPage extends StatefulWidget {
  final String? blockId;
  final String? parentId;

  /// 刚为这次编辑新建的任务：什么都没填就返回时直接丢弃，不同步一条空任务。
  final bool discardIfEmpty;
  const TaskEditorPage({super.key, this.blockId, this.parentId, this.discardIfEmpty = false});

  @override
  State<TaskEditorPage> createState() => _TaskEditorPageState();
}

class _TaskEditorPageState extends State<TaskEditorPage> {
  late final TextEditingController _title;
  late final TextEditingController _notes;
  String? _id;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _title = TextEditingController();
    _notes = TextEditingController();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_ready) return;
    _ready = true;
    final sync = AppScope.of(context).sync;
    _sync = sync;
    final existing = widget.blockId == null ? null : sync.byId(widget.blockId!);
    if (existing != null) {
      _id = existing.id;
      _title.text = existing.title == '未命名任务' ? '' : existing.title;
      _notes.text = taskDataOf(existing).notes;
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _id != null) return;
      final created = saveTask(
        AppScope.of(context).sync,
        null,
        title: '未命名任务',
        data: const TaskData(),
        parentId: widget.parentId,
      );
      setState(() {
        _id = created?.id;
        _title.text = '';
      });
    });
  }

  SyncClient? _sync;

  /// 新建后什么都没填就返回：不要在所有设备上留下一条「未命名任务」（Things / Todoist 同样会丢弃空草稿）。
  static bool isPristineTask(Block b) {
    if (b.title != '未命名任务' && b.title.trim().isNotEmpty) return false;
    final d = taskDataOf(b);
    return d.items.isEmpty &&
        d.startAt == null &&
        d.dueAt == null &&
        d.notes.trim().isEmpty &&
        d.status == TaskStatus.todo &&
        d.priority == TaskPriority.none &&
        !d.flagged &&
        !d.milestone;
  }

  @override
  void dispose() {
    final id = _id, sync = _sync;
    if (widget.discardIfEmpty && id != null && sync != null && _title.text.trim().isEmpty) {
      final b = sync.byId(id);
      final hasChildren = sync.blocks.any((x) => x.parentId == id && !x.deleted);
      if (b != null && !b.deleted && !hasChildren && isPristineTask(b)) {
        // dispose 期间不能通知监听者（会在卸载中 setState），等这一帧结束再删。
        WidgetsBinding.instance.addPostFrameCallback((_) {
          final latest = sync.byId(id);
          if (latest != null && !latest.deleted && isPristineTask(latest)) sync.purge([id]);
        });
        WidgetsBinding.instance.scheduleFrame();
      }
    }
    _title.dispose();
    _notes.dispose();
    super.dispose();
  }

  Block? _block() {
    final id = _id;
    if (id == null) return null;
    return AppScope.of(context).sync.byId(id);
  }

  void _save(TaskData data, {String? title}) {
    final b = _block();
    if (b == null) return;
    final t = title ?? _title.text;
    saveTask(
      AppScope.of(context).sync,
      b,
      title: t.trim().isEmpty ? '未命名任务' : t.trim(),
      data: data,
      parentId: b.parentId,
    );
  }

  Future<int?> _pickDate(int? current, {required bool allDay}) async {
    final now = DateTime.now();
    final initial = current == null ? now : DateTime.fromMillisecondsSinceEpoch(current);
    final date = await showDatePicker(context: context, initialDate: initial, firstDate: DateTime(2000), lastDate: DateTime(2100));
    if (date == null) return null;
    if (allDay) return DateTime(date.year, date.month, date.day).millisecondsSinceEpoch;
    if (!mounted) return null;
    final time = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(initial));
    final hh = time?.hour ?? initial.hour;
    final mm = time?.minute ?? initial.minute;
    return DateTime(date.year, date.month, date.day, hh, mm).millisecondsSinceEpoch;
  }

  Future<void> _editItemDates(Block block, ProgressItem item) async {
    final data = taskDataOf(block);
    final start = await _pickDate(item.startAt, allDay: data.allDay);
    if (!mounted) return;
    var next = item;
    if (start != null) next = next.copyWith(startAt: start);
    final due = await _pickDate(item.dueAt, allDay: data.allDay);
    if (due != null) next = next.copyWith(dueAt: due);
    if (!mounted) return;
    upsertProgressItem(AppScope.of(context).sync, block, next);
  }

  Future<void> _addItem(Block block, ProgressItemKind kind) async {
    final sync = AppScope.of(context).sync;
    if (kind == ProgressItemKind.subtask) {
      final child = addSubtask(sync, block, title: '子任务');
      if (child == null) {
        showToast(context, '不能再往下拆分了（最多 5 层）');
        return;
      }
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => TaskEditorPage(blockId: child.id, parentId: block.id),
      ));
      return;
    }
    upsertProgressItem(
      sync,
      block,
      ProgressItem(id: newProgressItemId(), title: kind == ProgressItemKind.percent ? '部分完成项' : '进度项', kind: kind),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final c = AppColors.of(context);
    final tt = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: Listenable.merge([s.sync, Glass.backdropListenable]),
      builder: (context, _) {
        final block = _block();
        if (block == null) {
          return Scaffold(
            backgroundColor: Glass.scaffoldBg(context),
            appBar: AppBar(backgroundColor: Glass.scaffoldBg(context), title: const Text('任务')),
            body: const Center(child: Text('任务已删除')),
          );
        }
        final data = taskDataOf(block);
        final byId = taskIndexOf(s.sync);
        final progress = computeTaskProgress(block, byId);
        final health = taskHealthOf(block, byId);
        final kids = taskChildrenOf(block.id, byId);
        final dateWarn = datesInverted(data);
        final parent = block.parentId == null ? null : s.sync.byId(block.parentId!);
        final parentData = parent != null && isTaskBlock(parent) ? taskDataOf(parent) : null;
        final rangeWarn = parentData != null && subtaskOutsideParent(data, parentData);
        return Scaffold(
          key: const Key('taskEditor'),
          backgroundColor: Glass.scaffoldBg(context),
          appBar: AppBar(
            backgroundColor: Glass.scaffoldBg(context),
            title: Text(block.title.isEmpty ? '新任务' : block.title),
            actions: [
              IconButton(
                tooltip: data.flagged ? '取消旗标' : '标为今天（旗标）',
                onPressed: () => _save(data.copyWith(flagged: !data.flagged)),
                icon: Icon(data.flagged ? CupertinoIcons.flag_fill : CupertinoIcons.flag, color: data.flagged ? c.warning : c.text2),
              ),
              IconButton(
                key: const Key('taskTrashButton'),
                tooltip: '移入回收站',
                onPressed: () {
                  s.sync.delete(block.id);
                  Navigator.pop(context);
                  showToast(context, '已移入回收站');
                },
                icon: Icon(CupertinoIcons.trash, color: c.danger),
              ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(Gap.xl, Gap.m, Gap.xl, Gap.x4),
            children: [
              TextField(
                key: const Key('taskTitleField'),
                controller: _title,
                style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w600, fontSize: 20, height: 1.3),
                decoration: const InputDecoration(hintText: '任务标题', border: InputBorder.none, isDense: true),
                onChanged: (v) => _save(data, title: v),
                textInputAction: TextInputAction.next,
              ),
              const SizedBox(height: Gap.m),
              Row(
                children: [
                  TaskProgressRing(progress: progress, color: taskHealthColor(c, health), size: 28, stroke: 3),
                  const SizedBox(width: Gap.m),
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(99),
                      child: LinearProgressIndicator(minHeight: 6, value: progress, backgroundColor: c.separator, color: taskHealthColor(c, health)),
                    ),
                  ),
                  const SizedBox(width: Gap.m),
                  Text(formatProgressPct(progress), style: tt.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
                ],
              ),
              const SizedBox(height: Gap.s),
              Text(taskHealthLabel(health), style: tt.bodySmall?.copyWith(color: taskHealthColor(c, health))),
              const SizedBox(height: Gap.xl),
              _label(context, '状态与优先级'),
              Wrap(
                spacing: Gap.s,
                runSpacing: Gap.s,
                children: [
                  for (final st in TaskStatus.values)
                    ChoiceChip(
                      key: Key('taskStatus-${st.name}'),
                      label: Text(taskStatusLabel(st)),
                      selected: data.status == st,
                      onSelected: (_) {
                        if (st == TaskStatus.done) {
                          setTaskCompleted(s.sync, block, true);
                        } else if (data.status == TaskStatus.done) {
                          setTaskCompleted(s.sync, block, false);
                          if (st != TaskStatus.todo) {
                            final latest = s.sync.byId(block.id) ?? block;
                            setTaskStatus(s.sync, latest, st);
                          }
                        } else {
                          setTaskStatus(s.sync, block, st);
                        }
                      },
                    ),
                ],
              ),
              const SizedBox(height: Gap.m),
              Wrap(
                spacing: Gap.s,
                runSpacing: Gap.s,
                children: [
                  for (final p in TaskPriority.values)
                    ChoiceChip(
                      key: Key('taskPriority-${p.name}'),
                      label: Text(taskPriorityLabel(p)),
                      selected: data.priority == p,
                      onSelected: (_) => _save(data.copyWith(priority: p)),
                    ),
                ],
              ),
              SwitchListTile.adaptive(
                key: const Key('taskMilestoneToggle'),
                contentPadding: EdgeInsets.zero,
                title: const Text('里程碑'),
                subtitle: const Text('在仪表盘里单独列出的关键节点'),
                value: data.milestone,
                onChanged: (v) => _save(data.copyWith(milestone: v)),
              ),
              const SizedBox(height: Gap.l),
              _label(context, '时间'),
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                title: const Text('全天'),
                value: data.allDay,
                onChanged: (v) => _save(data.copyWith(allDay: v)),
              ),
              _DateRow(
                label: '开始',
                value: formatTaskDate(data.startAt, allDay: data.allDay),
                onPick: () async {
                  final v = await _pickDate(data.startAt, allDay: data.allDay);
                  if (v != null) _save(data.copyWith(startAt: v));
                },
                onClear: data.startAt == null ? null : () => _save(data.copyWith(clearStart: true)),
              ),
              _DateRow(
                label: '截止',
                value: formatTaskDate(data.dueAt, allDay: data.allDay),
                onPick: () async {
                  final v = await _pickDate(data.dueAt, allDay: data.allDay);
                  if (v != null) _save(data.copyWith(dueAt: v));
                },
                onClear: data.dueAt == null ? null : () => _save(data.copyWith(clearDue: true)),
              ),
              _DateRow(
                key: const Key('taskCompletedAt'),
                label: '完成',
                value: formatTaskDate(data.completedAt, allDay: data.allDay),
                hint: data.status == TaskStatus.done ? '勾选完成时自动记录，可改正' : '完成后自动记录',
                onPick: data.status == TaskStatus.done
                    ? () async {
                        final v = await _pickDate(data.completedAt, allDay: data.allDay);
                        if (v != null) _save(data.copyWith(status: TaskStatus.done, completedAt: v));
                      }
                    : null,
              ),
              if (dateWarn)
                Padding(
                  padding: const EdgeInsets.only(top: Gap.s),
                  child: Text('开始时间晚于截止时间，建议调整。', style: tt.bodySmall?.copyWith(color: c.warning)),
                ),
              if (rangeWarn)
                Padding(
                  padding: const EdgeInsets.only(top: Gap.s),
                  child: Text('子任务的时间不在父任务的起止范围内。', style: tt.bodySmall?.copyWith(color: c.warning)),
                ),
              const SizedBox(height: Gap.xl),
              _label(context, '进度组成'),
              Text('为这项任务定义进度都有什么、各占多少。加权按你设的比重计算；均分则每项相同。新增项目后总进度可能下降。', style: tt.bodySmall?.copyWith(color: c.text2)),
              const SizedBox(height: Gap.s),
              Wrap(
                spacing: Gap.s,
                children: [
                  for (final m in ProgressMode.values)
                    ChoiceChip(
                      key: Key('taskMode-${m.name}'),
                      label: Text(switch (m) {
                        ProgressMode.weighted => '加权',
                        ProgressMode.equal => '均分',
                        ProgressMode.manual => '手动',
                      }),
                      selected: data.progressMode == m,
                      onSelected: (_) => _save(data.copyWith(progressMode: m)),
                    ),
                ],
              ),
              if (data.progressMode == ProgressMode.manual)
                Slider(
                  key: const Key('taskManualSlider'),
                  value: data.manualProgress.clamp(0, 1),
                  label: formatProgressPct(data.manualProgress),
                  onChanged: (v) {
                    var next = data.copyWith(manualProgress: v);
                    if (next.status == TaskStatus.todo && v > 0) next = next.copyWith(status: TaskStatus.inProgress);
                    _save(next);
                  },
                ),
              const SizedBox(height: Gap.m),
              for (final item in data.items)
                _ItemCard(
                  item: item,
                  allDay: data.allDay,
                  showWeight: data.progressMode == ProgressMode.weighted,
                  child: item.subtaskId == null ? null : s.sync.byId(item.subtaskId!),
                  onToggle: () => toggleProgressItem(s.sync, block, item.id),
                  onPercent: (v) => toggleProgressItem(s.sync, block, item.id, percent: v, done: v >= 0.999),
                  onWeight: (w) => upsertProgressItem(s.sync, block, item.copyWith(weight: w)),
                  onTitle: (t) => upsertProgressItem(s.sync, block, item.copyWith(title: t)),
                  onDates: () => _editItemDates(block, item),
                  onClearDates: () => upsertProgressItem(s.sync, block, item.copyWith(clearStart: true, clearDue: true)),
                  onOpenChild: item.subtaskId == null
                      ? null
                      : () => Navigator.of(context).push(MaterialPageRoute(
                            builder: (_) => TaskEditorPage(blockId: item.subtaskId, parentId: block.id),
                          )),
                  onRemove: () {
                    if (item.kind == ProgressItemKind.subtask && item.subtaskId != null) {
                      s.sync.delete(item.subtaskId!);
                    }
                    removeProgressItem(s.sync, block, item.id);
                  },
                ),
              const SizedBox(height: Gap.s),
              Wrap(
                spacing: Gap.s,
                children: [
                  OutlinedButton.icon(
                    key: const Key('addProgressItemButton'),
                    onPressed: () => _addItem(block, ProgressItemKind.check),
                    icon: const Icon(CupertinoIcons.plus, size: 16),
                    label: const Text('添加进度项'),
                  ),
                  OutlinedButton.icon(
                    key: const Key('addPercentItemButton'),
                    onPressed: () => _addItem(block, ProgressItemKind.percent),
                    icon: const Icon(CupertinoIcons.percent, size: 16),
                    label: const Text('部分完成项'),
                  ),
                  OutlinedButton.icon(
                    key: const Key('addSubtaskButton'),
                    onPressed: () => _addItem(block, ProgressItemKind.subtask),
                    icon: const Icon(CupertinoIcons.collections, size: 16),
                    label: const Text('添加子任务'),
                  ),
                ],
              ),
              if (kids.isNotEmpty) ...[
                const SizedBox(height: Gap.xl),
                _label(context, '子任务'),
                for (final child in kids)
                  ListTile(
                    key: Key('subtaskRow-${child.id}'),
                    contentPadding: EdgeInsets.zero,
                    leading: TaskProgressRing(
                      progress: computeTaskProgress(child, byId),
                      color: taskHealthColor(c, taskHealthOf(child, byId)),
                    ),
                    title: Text(child.title),
                    subtitle: Text(taskDateCaption(child)),
                    trailing: Text(formatProgressPct(computeTaskProgress(child, byId))),
                    onTap: () => Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => TaskEditorPage(blockId: child.id, parentId: block.id),
                    )),
                  ),
              ],
              const SizedBox(height: Gap.xl),
              _label(context, '备注'),
              TextField(
                key: const Key('taskNotesField'),
                controller: _notes,
                minLines: 3,
                maxLines: 8,
                decoration: InputDecoration(
                  hintText: '补充说明（可选）',
                  filled: true,
                  fillColor: c.fill.withValues(alpha: 0.6),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(AppRadius.m), borderSide: BorderSide(color: c.separator)),
                ),
                onChanged: (v) => _save(data.copyWith(notes: v)),
              ),
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                title: const Text('子项全部完成时自动完成此任务'),
                value: data.autoCompleteParent,
                onChanged: (v) => _save(data.copyWith(autoCompleteParent: v)),
              ),
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                title: const Text('完成此任务时一并完成子任务'),
                subtitle: const Text('默认关闭，避免误把未做完的子任务勾掉'),
                value: data.autoCompleteChildren,
                onChanged: (v) => _save(data.copyWith(autoCompleteChildren: v)),
              ),
            ],
          ),
        );
      },
    );
  }
}

Widget _label(BuildContext context, String text) {
  return Padding(
    padding: const EdgeInsets.only(bottom: Gap.s),
    child: Text(text, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppColors.of(context).text2, fontWeight: FontWeight.w600)),
  );
}

class _DateRow extends StatelessWidget {
  final String label;
  final String value;
  final VoidCallback? onPick;
  final VoidCallback? onClear;
  final String? hint;
  const _DateRow({super.key, required this.label, required this.value, this.onPick, this.onClear, this.hint});

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      minVerticalPadding: 0,
      title: Text(label),
      subtitle: Text(value.isEmpty ? (hint ?? '未设置') : value, style: TextStyle(color: value.isEmpty ? c.text3 : c.text2)),
      trailing: onClear == null ? null : IconButton(tooltip: '清除', onPressed: onClear, icon: const Icon(CupertinoIcons.xmark_circle, size: 18)),
      enabled: onPick != null,
      onTap: onPick,
    );
  }
}

class _ItemCard extends StatelessWidget {
  final ProgressItem item;
  final bool allDay;
  final bool showWeight;
  final Block? child;
  final VoidCallback onToggle;
  final ValueChanged<double> onPercent;
  final ValueChanged<double> onWeight;
  final ValueChanged<String> onTitle;
  final VoidCallback onDates;
  final VoidCallback onClearDates;
  final VoidCallback? onOpenChild;
  final VoidCallback onRemove;

  const _ItemCard({
    required this.item,
    required this.allDay,
    required this.showWeight,
    required this.child,
    required this.onToggle,
    required this.onPercent,
    required this.onWeight,
    required this.onTitle,
    required this.onDates,
    required this.onClearDates,
    required this.onOpenChild,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final tt = Theme.of(context).textTheme;
    final dates = [
      if (item.startAt != null) '开始 ${formatTaskDate(item.startAt, allDay: allDay)}',
      if (item.dueAt != null) '截止 ${formatTaskDate(item.dueAt, allDay: allDay)}',
    ].join(' · ');
    return Container(
      key: Key('progressItem-${item.id}'),
      margin: const EdgeInsets.only(bottom: Gap.s),
      padding: const EdgeInsets.fromLTRB(Gap.s, Gap.s, Gap.s, Gap.m),
      decoration: BoxDecoration(
        color: c.fill.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(AppRadius.m),
        border: Border.all(color: c.separator.withValues(alpha: 0.55)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SizedBox.square(
                dimension: Sizes.bar,
                child: IconButton(
                  tooltip: item.done ? '标为未完成' : '标为完成',
                  onPressed: item.kind == ProgressItemKind.subtask ? onOpenChild : onToggle,
                  icon: Icon(
                    item.kind == ProgressItemKind.subtask
                        ? CupertinoIcons.collections
                        : (item.done || item.percent >= 0.999 ? CupertinoIcons.checkmark_alt_circle_fill : CupertinoIcons.circle),
                    color: item.done || item.percent >= 0.999 ? c.success : c.text3,
                  ),
                ),
              ),
              Expanded(
                child: TextFormField(
                  key: Key('progressItemTitle-${item.id}'),
                  initialValue: item.title,
                  decoration: const InputDecoration(border: InputBorder.none, isDense: true, hintText: '进度项标题'),
                  onChanged: onTitle,
                ),
              ),
              if (showWeight)
                SizedBox(
                  width: 64,
                  child: TextFormField(
                    key: Key('progressItemWeight-${item.id}'),
                    initialValue: item.weight == item.weight.roundToDouble() ? '${item.weight.round()}' : '${item.weight}',
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(isDense: true, labelText: '权重', border: OutlineInputBorder()),
                    onChanged: (v) {
                      final n = double.tryParse(v);
                      if (n != null && n > 0) onWeight(n);
                    },
                  ),
                ),
              IconButton(tooltip: '删除', onPressed: onRemove, icon: Icon(CupertinoIcons.minus_circle, color: c.danger, size: 20)),
            ],
          ),
          if (item.kind == ProgressItemKind.percent)
            Slider(value: item.percent.clamp(0, 1), onChanged: onPercent, label: formatProgressPct(item.percent)),
          Padding(
            padding: const EdgeInsets.only(left: Gap.s),
            child: Wrap(
              spacing: Gap.m,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(switch (item.kind) {
                  ProgressItemKind.check => '勾选项',
                  ProgressItemKind.percent => '百分比',
                  ProgressItemKind.subtask => '子任务',
                }, style: tt.bodySmall?.copyWith(color: c.text2)),
                TextButton(
                  onPressed: item.kind == ProgressItemKind.subtask ? onOpenChild : onDates,
                  child: Text(item.kind == ProgressItemKind.subtask ? '打开子任务' : (dates.isEmpty ? '设置起止时间' : dates)),
                ),
                if (dates.isNotEmpty && item.kind != ProgressItemKind.subtask)
                  TextButton(onPressed: onClearDates, child: const Text('清除时间')),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
