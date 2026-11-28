import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../models/block.dart';
import '../tasks/task_actions.dart';
import '../tasks/task_models.dart';
import '../tasks/task_queries.dart';
import 'ds.dart';
import 'glass.dart';
import 'home_page.dart' show FilterTab;
import 'task_editor_page.dart';
import 'task_widgets.dart';

/// 任务仪表盘：总览卡片、智能列表、进度环。从侧边栏「任务」进入，不改收件箱顶栏。
class TaskDashboardPage extends StatefulWidget {
  const TaskDashboardPage({super.key});

  @override
  State<TaskDashboardPage> createState() => _TaskDashboardPageState();
}

class _TaskDashboardPageState extends State<TaskDashboardPage> {
  TaskSmartView _view = TaskSmartView.overview;
  TaskSort _sort = TaskSort.priority;
  String _query = '';
  final _search = TextEditingController();
  bool _searching = false;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _open(Block? block, {String? parentId}) async {
    var target = block;
    target ??= saveTask(AppScope.of(context).sync, null, title: '未命名任务', data: const TaskData(), parentId: parentId);
    if (target == null || !mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => TaskEditorPage(blockId: target!.id, parentId: parentId ?? target.parentId, discardIfEmpty: block == null),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final c = AppColors.of(context);
    final tt = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: Listenable.merge([s.sync, Glass.backdropListenable]),
      builder: (context, _) {
        final bg = Glass.scaffoldBg(context);
        final now = DateTime.now();
        final stats = dashboardStats(s.sync, now: now);
        final items = tasksForView(s.sync, _view, sort: _sort, now: now, query: _query);
        final active = [for (final b in items) if (taskDataOf(b).status != TaskStatus.done) b];
        final done = [for (final b in items) if (taskDataOf(b).status == TaskStatus.done) b];
        return Scaffold(
          key: const Key('taskDashboard'),
          backgroundColor: bg,
          appBar: AppBar(
            backgroundColor: bg,
            title: _searching
                ? TextField(
                    key: const Key('taskSearchField'),
                    controller: _search,
                    autofocus: true,
                    decoration: const InputDecoration(
                      hintText: '搜索任务',
                      border: InputBorder.none,
                      isDense: true,
                    ),
                    onChanged: (v) => setState(() => _query = v),
                  )
                : const Text('任务'),
            actions: [
              IconButton(
                key: const Key('taskSearchButton'),
                tooltip: _searching ? '关闭搜索' : '搜索',
                icon: Icon(_searching ? CupertinoIcons.xmark : CupertinoIcons.search),
                onPressed: () {
                  setState(() {
                    _searching = !_searching;
                    if (!_searching) {
                      _search.clear();
                      _query = '';
                    }
                  });
                },
              ),
              PopupMenuButton<TaskSort>(
                key: const Key('taskSortButton'),
                tooltip: '排序',
                onSelected: (v) => setState(() => _sort = v),
                itemBuilder: (context) => [
                  for (final srt in TaskSort.values)
                    PopupMenuItem(
                      value: srt,
                      child: Text(srt == _sort ? '✓ ${taskSortLabel(srt)}' : taskSortLabel(srt)),
                    ),
                ],
                child: const SizedBox.square(
                  dimension: Sizes.bar,
                  child: Icon(CupertinoIcons.sort_down, size: Sizes.iconMd),
                ),
              ),
              IconButton(
                key: const Key('newTaskButton'),
                tooltip: '新建任务',
                icon: const Icon(CupertinoIcons.add),
                onPressed: () => _open(null),
              ),
              const SizedBox(width: Gap.s),
            ],
          ),
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                height: Sizes.bar,
                child: ListView(
                  key: const Key('taskViewRow'),
                  scrollDirection: Axis.horizontal,
                  // 与首页同一个 FilterTab（胶囊、同高同色），不再用另一套描边 Chip。
                  padding: const EdgeInsets.symmetric(horizontal: Gap.l),
                  children: [
                    for (final v in TaskSmartView.values)
                      Padding(
                        padding: const EdgeInsets.only(right: Gap.xs),
                        child: FilterTab(
                          key: Key('taskView-${v.name}'),
                          label: taskSmartViewLabel(v),
                          selected: _view == v,
                          onTap: () => setState(() => _view = v),
                          hitHeight: Sizes.bar,
                        ),
                      ),
                  ],
                ),
              ),
              // 一条任务都没有时只显示空状态，不再摆一排全是 0 的统计卡（信息层级）。
              if (_view == TaskSmartView.overview && s.sync.blocks.any((b) => isTaskBlock(b) && !b.deleted && b.deletedAt == null))
                _Overview(stats: stats, onTap: (v) => setState(() => _view = v)),
              Expanded(
                child: items.isEmpty
                    ? EmptyTasks(query: _query, onCreate: () => _open(null))
                    : ListView(
                        padding: const EdgeInsets.fromLTRB(Gap.l, Gap.s, Gap.l, Gap.x4),
                        children: [
                          for (final b in active) _TaskTile(block: b, now: now, onTap: () => _open(b)),
                          if (done.isNotEmpty) ...[
                            Padding(
                              padding: const EdgeInsets.fromLTRB(Gap.s, Gap.xl, Gap.s, Gap.m),
                              child: Text(
                                '已完成 · ${done.length}',
                                style: tt.bodySmall?.copyWith(color: c.text2, fontWeight: FontWeight.w500),
                              ),
                            ),
                            for (final b in done) _TaskTile(block: b, now: now, onTap: () => _open(b)),
                          ],
                        ],
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _Overview extends StatelessWidget {
  final TaskDashboardStats stats;
  final void Function(TaskSmartView view) onTap;
  const _Overview({required this.stats, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final tt = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.l, Gap.s, Gap.l, Gap.m),
      child: Column(
        children: [
          Container(
            key: const Key('taskOverviewRing'),
            padding: const EdgeInsets.all(Gap.l),
            decoration: BoxDecoration(
              color: c.fill.withValues(alpha: 0.65),
              borderRadius: BorderRadius.circular(AppRadius.l),
              border: Border.all(color: c.separator.withValues(alpha: 0.6)),
            ),
            child: Row(
              children: [
                TaskProgressRing(
                  progress: stats.active == 0 && stats.completedThisWeek == 0 ? 0 : stats.workProgress,
                  color: c.accent,
                  size: 44,
                  stroke: 4,
                ),
                const SizedBox(width: Gap.l),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('整体进度 ${formatProgressPct(stats.workProgress)}', style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
                      const SizedBox(height: 2),
                      Text(
                        stats.active == 0 ? '还没有进行中的任务' : '${stats.active} 项进行中 · 本周完成 ${stats.completedThisWeek} 项',
                        style: tt.bodySmall?.copyWith(color: c.text2),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: Gap.m),
          Row(
            children: [
              _StatCard(key: const Key('stats-overdue'), label: '逾期', value: stats.overdue, color: c.danger, onTap: () => onTap(TaskSmartView.overdue)),
              const SizedBox(width: Gap.m),
              _StatCard(key: const Key('stats-today'), label: '今天', value: stats.today, color: c.accent, onTap: () => onTap(TaskSmartView.today)),
              const SizedBox(width: Gap.m),
              _StatCard(key: const Key('stats-progress'), label: '进行中', value: stats.inProgress, color: c.success, onTap: () => onTap(TaskSmartView.inProgress)),
              const SizedBox(width: Gap.m),
              _StatCard(key: const Key('stats-risk'), label: '有风险', value: stats.atRisk, color: c.warning, onTap: () => onTap(TaskSmartView.atRisk)),
            ],
          ),
        ],
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  final String label;
  final int value;
  final Color color;
  final VoidCallback onTap;
  const _StatCard({super.key, required this.label, required this.value, required this.color, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final tt = Theme.of(context).textTheme;
    return Expanded(
      child: Material(
        color: c.fill.withValues(alpha: 0.65),
        borderRadius: BorderRadius.circular(AppRadius.m),
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadius.m),
          onTap: onTap,
          child: Container(
            height: 64,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppRadius.m),
              border: Border.all(color: c.separator.withValues(alpha: 0.55)),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // 0 用中性色；只有真的有逾期 / 风险时才用语义色提醒，避免满屏彩色数字。
                Text('$value', style: tt.titleMedium?.copyWith(color: value == 0 ? c.text3 : color, fontWeight: FontWeight.w600, height: 1.1)),
                const SizedBox(height: 2),
                Text(label, style: tt.bodySmall?.copyWith(color: c.text2, fontSize: 11)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TaskTile extends StatelessWidget {
  final Block block;
  final DateTime now;
  final VoidCallback onTap;
  const _TaskTile({required this.block, required this.now, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final c = AppColors.of(context);
    final tt = Theme.of(context).textTheme;
    final byId = taskIndexOf(s.sync);
    final data = taskDataOf(block);
    final progress = computeTaskProgress(block, byId);
    final health = taskHealthOf(block, byId, now: now);
    final caption = taskDateCaption(block, now: now);
    final parentTitle = parentTaskTitle(block, byId);
    final done = data.status == TaskStatus.done;
    return Padding(
      padding: const EdgeInsets.only(bottom: Gap.s),
      child: Material(
        color: c.fill.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(AppRadius.m),
        child: InkWell(
          key: Key('taskRow-${block.id}'),
          borderRadius: BorderRadius.circular(AppRadius.m),
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: Sizes.listRow),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: Gap.m, vertical: Gap.s),
              child: Row(
                children: [
                  SizedBox.square(
                    dimension: Sizes.bar,
                    child: IconButton(
                      key: Key('taskComplete-${block.id}'),
                      tooltip: done ? '取消完成' : '标为已完成',
                      padding: EdgeInsets.zero,
                      onPressed: () => setTaskCompleted(s.sync, block, !done),
                      icon: Icon(
                        done ? CupertinoIcons.checkmark_alt_circle_fill : CupertinoIcons.circle,
                        size: 22,
                        color: done ? c.success : c.text3,
                      ),
                    ),
                  ),
                  TaskProgressRing(progress: progress, color: taskHealthColor(c, health)),
                  const SizedBox(width: Gap.m),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          block.title.isEmpty ? '未命名任务' : block.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: tt.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w500,
                            decoration: done ? TextDecoration.lineThrough : null,
                            color: done ? c.text2 : c.text,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          [
                            ?parentTitle,
                            if (data.milestone) '里程碑',
                            if (data.flagged) '旗标',
                            if (caption.isNotEmpty) caption,
                            if (health == TaskHealth.atRisk || health == TaskHealth.overdue) taskHealthLabel(health),
                          ].join(' · '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: tt.bodySmall?.copyWith(
                            color: health == TaskHealth.overdue
                                ? c.danger
                                : health == TaskHealth.atRisk
                                    ? c.warning
                                    : c.text2,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: Gap.s),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(formatProgressPct(progress), style: tt.bodySmall?.copyWith(color: c.text, fontWeight: FontWeight.w500)),
                      TaskPriorityFlag(priority: data.priority),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class EmptyTasks extends StatelessWidget {
  final String query;
  final VoidCallback onCreate;
  const EmptyTasks({super.key, required this.query, required this.onCreate});

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final tt = Theme.of(context).textTheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Gap.x4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(query.isEmpty ? CupertinoIcons.checkmark_alt_circle : CupertinoIcons.search, size: 36, color: c.text3),
            const SizedBox(height: Gap.l),
            Text(query.isEmpty ? '还没有任务' : '没有匹配的任务', style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: Gap.s),
            Text(
              query.isEmpty ? '把一项工作拆成带权重的进度项和子任务，跟踪起止时间和完成情况。' : '换个关键词试试',
              textAlign: TextAlign.center,
              style: tt.bodySmall?.copyWith(color: c.text2),
            ),
            if (query.isEmpty) ...[
              const SizedBox(height: Gap.xl),
              FilledButton.icon(
                key: const Key('emptyNewTask'),
                onPressed: onCreate,
                icon: const Icon(CupertinoIcons.add, size: 16),
                label: const Text('新建任务'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
