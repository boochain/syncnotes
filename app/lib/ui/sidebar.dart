import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../models/block.dart';
import '../pages/doc.dart';
import '../sync/sync_client.dart';
import 'context_menu.dart';
import 'ds.dart';
import 'glass.dart';
import 'home_page.dart' show ConnectionBadge;
import 'tokens.dart';
import '../tasks/task_queries.dart';


Widget? _overdueBadge(AppServices s) {
  final n = overdueRootCount(s.sync);
  if (n <= 0) return null;
  return CountBadge(n);
}

/// 侧边栏（布局照 AppFlowy / Notion + Apple HIG 材质）：顶部用户行 44（含一键日夜切换与侧边栏收起），导航与页面树每行 32，分组标题行 32；
/// 选中 / 悬停都用中性灰叠加，不用强调色铺底；桌面端页面树支持原生右键上下文菜单。
class Sidebar extends StatelessWidget {
  final String? selectedPage; // null = 收件箱
  final bool inboxSelected;
  final bool settingsSelected;
  final void Function(String? pageId) onSelect;
  final VoidCallback onSearch;
  final VoidCallback onSettings;
  final bool trashSelected;
  final VoidCallback? onTrash;
  final bool tasksSelected;
  final VoidCallback? onTasks;
  final bool transfersSelected;
  final VoidCallback? onTransfers;
  final bool calendarSelected;
  final VoidCallback? onCalendar;
  final VoidCallback? onToggleSidebar;
  const Sidebar({
    super.key,
    required this.selectedPage,
    required this.inboxSelected,
    this.settingsSelected = false,
    required this.onSelect,
    required this.onSearch,
    required this.onSettings,
    this.trashSelected = false,
    this.onTrash,
    this.tasksSelected = false,
    this.onTasks,
    this.transfersSelected = false,
    this.onTransfers,
    this.calendarSelected = false,
    this.onCalendar,
    this.onToggleSidebar,
  });

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final c = AppColors.of(context);
    final tt = Theme.of(context).textTheme;
    return Material(
      type: MaterialType.transparency,
      child: SafeArea(
        right: false,
        child: ListenableBuilder(
          listenable: s.sync,
          builder: (context, _) {
            final roots = rootPages(s.sync);
            final name = s.settings.username ?? '';
            return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              SizedBox(
                key: const Key('sidebarHeader'),
                height: Glass.surfaceTranslucent ? 54 : Sizes.bar,
                child: Padding(
                  padding: const EdgeInsets.only(left: Gap.l, right: Gap.m),
                  child: Row(children: [
                    Container(
                      width: 30,
                      height: 30,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: c.text2.withValues(alpha: 0.20),
                        shape: BoxShape.circle,
                        border: Border.all(color: c.separator.withValues(alpha: 0.6)),
                      ),
                      child: name.isEmpty
                          ? Icon(CupertinoIcons.person_fill, size: 15, color: c.text2)
                          : Text(
                              name.characters.first.toUpperCase(),
                              textScaler: TextScaler.noScaling,
                              style: TextStyle(fontSize: 13, height: 1.0, fontWeight: FontWeight.w600, color: c.text),
                            ),
                    ),
                    const SizedBox(width: Gap.m),
                    Expanded(
                      child: MediaQuery.withClampedTextScaling(
                        maxScaleFactor: 1.2,
                        child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            name.isEmpty ? 'Account' : name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: tt.labelLarge?.copyWith(fontSize: 13.5, fontWeight: FontWeight.w600, height: 1.15),
                          ),
                          const SizedBox(height: 1),
                          ConnectionBadge(sync: s.sync, compact: true),
                        ],
                        ),
                      ),
                    ),
                    ValueListenableBuilder<ThemeMode>(
                      valueListenable: s.themeMode,
                      builder: (context, mode, _) {
                        final dark = Theme.of(context).brightness == Brightness.dark;
                        return Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Tooltip(
                              message: '浅色模式',
                              child: InkWell(
                                key: const Key('sidebarThemeToggle'),
                                borderRadius: BorderRadius.circular(AppRadius.xs),
                                onTap: () {
                                  final next = mode == ThemeMode.light ? ThemeMode.dark : ThemeMode.light;
                                  s.themeMode.value = next;
                                  s.settings.themeMode = next.name;
                                },
                                child: SizedBox.square(
                                  dimension: 24,
                                  child: Icon(
                                    CupertinoIcons.sun_max_fill,
                                    size: 14,
                                    color: !dark ? c.text : c.text3,
                                  ),
                                ),
                              ),
                            ),
                            Tooltip(
                              message: '深色模式',
                              child: InkWell(
                                borderRadius: BorderRadius.circular(AppRadius.xs),
                                onTap: () {
                                  final next = mode == ThemeMode.dark ? ThemeMode.system : ThemeMode.dark;
                                  s.themeMode.value = next;
                                  s.settings.themeMode = next.name;
                                },
                                child: SizedBox.square(
                                  dimension: 24,
                                  child: Icon(
                                    CupertinoIcons.moon_fill,
                                    size: 13.5,
                                    color: dark ? c.text : c.text3,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                    if (onToggleSidebar != null) ...[
                      const SizedBox(width: 2),
                      SmallIconButton(
                        key: const Key('sidebarCollapseButton'),
                        tooltip: '收起侧边栏 (Ctrl+\\)',
                        icon: CupertinoIcons.sidebar_left,
                        onPressed: onToggleSidebar,
                      ),
                    ],
                  ]),
                ),
              ),
              // 概念图同款圆角毛玻璃搜索框胶囊
              Padding(
                padding: const EdgeInsets.fromLTRB(Gap.m, Gap.xs, Gap.m, Gap.m),
                child: InkWell(
                  key: const Key('sidebarSearch'),
                  borderRadius: BorderRadius.circular(9),
                  onTap: onSearch,
                  child: Container(
                    height: Sizes.control,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    decoration: BoxDecoration(
                      color: c.fill.withValues(alpha: 0.72),
                      borderRadius: BorderRadius.circular(9),
                      border: Border.all(color: c.separator.withValues(alpha: 0.55), width: 0.8),
                    ),
                    child: Row(
                      children: [
                        Icon(CupertinoIcons.search, size: 13.5, color: c.text3),
                        const SizedBox(width: 7),
                        Expanded(
                          child: Text('搜索', style: tt.bodySmall?.copyWith(color: c.text3, fontSize: 12.5)),
                        ),
                        Text('Ctrl K', maxLines: 1, style: tt.bodySmall?.copyWith(color: c.text3, fontSize: 10.5)),
                      ],
                    ),
                  ),
                ),
              ),
              SidebarRow(
                key: const Key('sidebarInbox'),
                leading: Icon(CupertinoIcons.tray_fill, color: c.accent),
                label: '收件箱',
                selected: inboxSelected,
                trailing: s.sync.unreadCount > 0 ? CountBadge(s.sync.unreadCount) : null,
                onTap: () => onSelect(null),
              ),
              if (onTasks != null)
                SidebarRow(
                  key: const Key('sidebarTasks'),
                  leading: Icon(CupertinoIcons.checkmark_alt_circle_fill, color: c.accent),
                  label: '任务',
                  selected: tasksSelected,
                  trailing: _overdueBadge(s),
                  onTap: onTasks!,
                ),
              if (onCalendar != null)
                SidebarRow(
                  key: const Key('sidebarCalendar'),
                  leading: Icon(CupertinoIcons.calendar, color: c.accent),
                  label: '日历',
                  selected: calendarSelected,
                  onTap: onCalendar!,
                ),
              SidebarRow(
                key: const Key('sidebarSettings'),
                leading: Icon(CupertinoIcons.gear_alt_fill, color: c.accent),
                label: '设置',
                selected: settingsSelected,
                onTap: onSettings,
              ),
              if (onTrash != null)
                SidebarRow(
                  key: const Key('sidebarTrash'),
                  leading: Icon(CupertinoIcons.trash_fill, color: c.accent),
                  label: '回收站',
                  selected: trashSelected,
                  trailing: s.sync.trash.isNotEmpty
                      ? Text('${s.sync.trash.length}', maxLines: 1, style: tt.bodySmall?.copyWith(color: c.text3))
                      : null,
                  onTap: onTrash!,
                ),
              if (onTransfers != null)
                SidebarRow(
                  key: const Key('sidebarTransfers'),
                  leading: Icon(CupertinoIcons.arrow_up_arrow_down, color: c.accent),
                  label: '传输',
                  selected: transfersSelected,
                  trailing: ListenableBuilder(
                    listenable: s.transfers,
                    builder: (context, _) => s.transfers.activeCount > 0 ? CountBadge(s.transfers.activeCount) : const SizedBox.shrink(),
                  ),
                  onTap: onTransfers!,
                ),
              const SizedBox(height: Gap.l),
              SizedBox(
                height: Sizes.control,
                child: Padding(
                  padding: const EdgeInsets.only(left: Gap.xl, right: Gap.l),
                  child: Row(children: [
                    Expanded(child: Text('页面', style: tt.bodySmall?.copyWith(color: c.text2, fontWeight: FontWeight.w500))),
                    SmallIconButton(
                      key: const Key('newRootPage'),
                      tooltip: '新建页面',
                      icon: CupertinoIcons.add,
                      onPressed: () => onSelect(createPage(s.sync, null)),
                    ),
                  ]),
                ),
              ),
              Expanded(
                child: roots.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.symmetric(horizontal: Gap.xl, vertical: Gap.m),
                        child: Text('还没有页面，点击 + 新建', style: tt.bodySmall),
                      )
                    : DragTarget<String>(
                        // 拖到列表空白处 → 移到根级末尾
                        onWillAcceptWithDetails: (d) => s.sync.byId(d.data)?.parentId != null,
                        onAcceptWithDetails: (d) => movePage(s.sync, d.data, null, DocController.nextRootOrder(s.sync, null)),
                        builder: (context, cand, _) => ListView(
                          padding: const EdgeInsets.only(bottom: Gap.l),
                          children: [
                            for (final p in roots)
                              PageTreeTile(page: p, depth: 0, selected: selectedPage, onSelect: (id) => onSelect(id)),
                          ],
                        ),
                      ),
              ),
            ]);
          },
        ),
      ),
    );
  }
}

/// 移动页面：改父级 + 顺序
void movePage(SyncClient sync, String id, String? parent, double order) {
  final b = sync.byId(id);
  if (b == null) return;
  if (parent != null && (parent == id || sync.descendantIds(id).contains(parent))) return;
  sync.update(id, parentId: parent, moveToRoot: parent == null, payload: {...b.payload, 'order': order});
}

/// 数字徽标（未读数）：高 18，最小宽 18
class CountBadge extends StatelessWidget {
  final int count;
  const CountBadge(this.count, {super.key});
  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Container(
      height: 18,
      constraints: const BoxConstraints(minWidth: 18),
      padding: const EdgeInsets.symmetric(horizontal: 5),
      alignment: Alignment.center,
      decoration: BoxDecoration(color: c.accent, borderRadius: BorderRadius.circular(9)),
      child: Text(count > 99 ? '99+' : '$count',
          textScaler: TextScaler.noScaling,
          style: const TextStyle(fontSize: 12, height: 1.0, fontWeight: FontWeight.w600, color: Colors.white)),
    );
  }
}

/// 24×24 的行内小图标按钮（侧边栏 +、行内操作）
class SmallIconButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  const SmallIconButton({super.key, required this.icon, required this.tooltip, this.onPressed});
  @override
  Widget build(BuildContext context) => Tooltip(
        message: tooltip,
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadius.xs),
          onTap: onPressed,
          child: SizedBox.square(dimension: 24, child: Icon(icon, size: Sizes.iconSm, color: AppColors.of(context).text2)),
        ),
      );
}

/// 侧边栏行：固定高度 32，左侧 20×20 图标位，标题 14，右侧附加内容；整行垂直居中。
class SidebarRow extends StatefulWidget {
  final Widget leading;
  final String label;
  final bool selected;
  final Widget? trailing;
  final Widget? hoverTrailing;
  final VoidCallback onTap;
  final GestureTapUpCallback? onSecondaryTapUp;
  final double indent;
  final Widget? prefix; // 展开箭头
  final Color? highlight;
  const SidebarRow({
    super.key,
    required this.leading,
    required this.label,
    this.selected = false,
    this.trailing,
    this.hoverTrailing,
    required this.onTap,
    this.onSecondaryTapUp,
    this.indent = 0,
    this.prefix,
    this.highlight,
  });
  @override
  State<SidebarRow> createState() => _SidebarRowState();
}

class _SidebarRowState extends State<SidebarRow> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final tt = Theme.of(context).textTheme;
    final touch = Theme.of(context).platform == TargetPlatform.android || Theme.of(context).platform == TargetPlatform.iOS;
    final trailing = (_hover || touch) && widget.hoverTrailing != null ? widget.hoverTrailing : widget.trailing;
    return MouseRegion(
      onEnter: (e) {
        if (isMouseHover(e)) setState(() => _hover = true);
      },
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        onSecondaryTapUp: widget.onSecondaryTapUp,
        child: AnimatedContainer(
          duration: Motion.short2,
          height: Sizes.control,
          margin: const EdgeInsets.symmetric(horizontal: Gap.m),
          padding: EdgeInsets.only(left: Gap.m + widget.indent, right: Gap.s),
          decoration: BoxDecoration(
            color: widget.highlight ?? (widget.selected ? c.selected : (_hover ? c.hover : Colors.transparent)),
            borderRadius: BorderRadius.circular(AppRadius.s),
          ),
          child: Row(children: [
            ?widget.prefix,
            SizedBox.square(
              dimension: Sizes.iconMd,
              child: IconTheme(data: IconThemeData(size: Sizes.iconSm, color: c.text2), child: Center(child: widget.leading)),
            ),
            const SizedBox(width: Gap.m),
            Expanded(
              child: Text(widget.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: (widget.selected ? tt.labelLarge : tt.bodyMedium)?.copyWith(color: c.text)),
            ),
            ?trailing,
          ]),
        ),
      ),
    );
  }
}

List<Block> rootPages(SyncClient sync) {
  final l = sync.blocks.where((b) {
    if (b.kind != BlockKind.page) return false;
    if (b.parentId == null) return true;
    final p = sync.byId(b.parentId!);
    return p == null || p.deleted || p.kind != BlockKind.page;
  }).toList()
    ..sort((a, b) => orderOf(a).compareTo(orderOf(b)));
  return l;
}

List<Block> childPages(SyncClient sync, String id) =>
    sync.blocks.where((b) => b.kind == BlockKind.page && b.parentId == id).toList()
      ..sort((a, b) => orderOf(a).compareTo(orderOf(b)));

/// 新建页面（parent 为 null 时是根页面）
String createPage(SyncClient sync, String? parent, {String title = ''}) => sync
    .create(
      kind: BlockKind.page,
      title: title,
      payload: {'icon': 'doc', 'order': DocController.nextRootOrder(sync, parent)},
      parentId: parent,
      viewedMode: ViewedMode.global,
    )
    .id;

/// 页面树节点：展开 / 收起、悬停新建子页面、桌面右键上下文菜单、拖动排序
class PageTreeTile extends StatefulWidget {
  final Block page;
  final int depth;
  final String? selected;
  final void Function(String id) onSelect;
  const PageTreeTile({super.key, required this.page, required this.depth, required this.selected, required this.onSelect});
  @override
  State<PageTreeTile> createState() => _PageTreeTileState();
}

enum _Drop { before, inside, after }

class _PageTreeTileState extends State<PageTreeTile> {
  bool _expanded = false;
  _Drop? _drop;
  final _rowKey = GlobalKey();

  _Drop _zone(Offset global) {
    final box = _rowKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return _Drop.inside;
    final y = box.globalToLocal(global).dy;
    if (y < Sizes.control * 0.28) return _Drop.before;
    if (y > Sizes.control * 0.72) return _Drop.after;
    return _Drop.inside;
  }

  void _accept(SyncClient sync, String id) {
    final p = widget.page;
    final zone = _drop ?? _Drop.inside;
    if (zone == _Drop.inside) {
      movePage(sync, id, p.id, DocController.nextRootOrder(sync, p.id));
      setState(() => _expanded = true);
      return;
    }
    final sibs = (p.parentId == null ? rootPages(sync) : childPages(sync, p.parentId!)).where((b) => b.id != id).toList();
    final i = sibs.indexWhere((b) => b.id == p.id);
    final mine = orderOf(p);
    double order;
    if (zone == _Drop.before) {
      order = i > 0 ? (orderOf(sibs[i - 1]) + mine) / 2 : mine - 1000;
    } else {
      order = i < sibs.length - 1 ? (orderOf(sibs[i + 1]) + mine) / 2 : mine + 1000;
    }
    movePage(sync, id, p.parentId, order);
  }

  Future<void> _renamePage(BuildContext context, SyncClient sync) async {
    final ctrl = TextEditingController(text: widget.page.title);
    final next = await showDialog<String>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('重命名页面'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(hintText: '页面标题'),
          onSubmitted: (v) => Navigator.pop(d, v.trim()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(d, ctrl.text.trim()), child: const Text('确定')),
        ],
      ),
    );
    ctrl.dispose();
    if (next == null) return;
    sync.update(widget.page.id, title: next);
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final c = AppColors.of(context);
    final kids = childPages(s.sync, widget.page.id);
    final sel = widget.selected == widget.page.id;
    final icon = (widget.page.payload['icon'] ?? 'doc') as String;
    final title = widget.page.title.isEmpty ? '无标题' : widget.page.title;
    final indent = 16.0 * widget.depth;
    final row = SidebarRow(
      key: ValueKey('tree-${widget.page.id}'),
      indent: indent - Gap.xs,
      selected: sel,
      highlight: _drop == _Drop.inside ? c.accent.withValues(alpha: 0.14) : null,
      prefix: GestureDetector(
        key: ValueKey('expand-${widget.page.id}'),
        behavior: HitTestBehavior.opaque,
        onTap: () => setState(() => _expanded = !_expanded),
        child: SizedBox(
          width: 20,
          height: Sizes.control,
          child: AnimatedRotation(
            turns: _expanded ? 0.25 : 0,
            duration: Motion.short4,
            child: Icon(CupertinoIcons.chevron_right, size: 12, color: kids.isEmpty ? c.text3 : c.text2),
          ),
        ),
      ),
      leading: Emoji(icon, size: Sizes.iconMd),
      label: title,
      hoverTrailing: SmallIconButton(
        tooltip: '新建子页面',
        icon: CupertinoIcons.add,
        onPressed: () {
          final id = createPage(s.sync, widget.page.id);
          setState(() => _expanded = true);
          widget.onSelect(id);
        },
      ),
      onTap: () => widget.onSelect(widget.page.id),
      onSecondaryTapUp: (d) => showGlassContextMenu(
        context,
        anchor: d.globalPosition,
        header: title,
        items: [
          ContextMenuItem(
            icon: CupertinoIcons.doc_text,
            label: '打开页面',
            onTap: () => widget.onSelect(widget.page.id),
          ),
          ContextMenuItem(
            icon: CupertinoIcons.add,
            label: '新建子页面',
            onTap: () {
              final id = createPage(s.sync, widget.page.id);
              setState(() => _expanded = true);
              widget.onSelect(id);
            },
          ),
          ContextMenuItem(
            icon: CupertinoIcons.pencil,
            label: '重命名',
            onTap: () => _renamePage(context, s.sync),
          ),
          const ContextMenuDivider(),
          ContextMenuItem(
            icon: CupertinoIcons.trash,
            label: '移入回收站',
            danger: true,
            onTap: () {
              final messenger = ScaffoldMessenger.maybeOf(context);
              final ids = s.sync.delete(widget.page.id);
              showToast(
                context,
                '已移到回收站：“$title”',
                messenger: messenger,
                actionLabel: '撤销',
                onAction: () => s.sync.restoreAll(ids),
              );
            },
          ),
        ],
      ),
    );
    final line = Container(height: 2, margin: EdgeInsets.only(left: Gap.m + indent + 20, right: Gap.m), color: c.accent);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      DragTarget<String>(
        onWillAcceptWithDetails: (d) => d.data != widget.page.id && !s.sync.descendantIds(d.data).contains(widget.page.id),
        onMove: (d) {
          final z = _zone(d.offset);
          if (z != _drop) setState(() => _drop = z);
        },
        onLeave: (_) => setState(() => _drop = null),
        onAcceptWithDetails: (d) {
          _accept(s.sync, d.data);
          setState(() => _drop = null);
        },
        builder: (context, cand, _) => Draggable<String>(
          key: _rowKey,
          data: widget.page.id,
          dragAnchorStrategy: pointerDragAnchorStrategy,
          feedback: Material(
            color: Colors.transparent,
            child: Container(
              height: Sizes.control,
              padding: const EdgeInsets.symmetric(horizontal: Gap.m),
              decoration: BoxDecoration(color: c.elevated.withValues(alpha: 0.88), borderRadius: BorderRadius.circular(AppRadius.m), border: Border.all(color: c.separator)),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Emoji(icon, size: Sizes.iconMd),
                const SizedBox(width: Gap.m),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 180),
                  child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodyMedium),
                ),
              ]),
            ),
          ),
          childWhenDragging: Opacity(opacity: 0.4, child: row),
          child: Stack(clipBehavior: Clip.none, children: [
            row,
            if (_drop == _Drop.before) Positioned(left: 0, right: 0, top: 0, child: line),
            if (_drop == _Drop.after) Positioned(left: 0, right: 0, bottom: 0, child: line),
          ]),
        ),
      ),
      AnimatedSize(
        duration: Motion.short4,
        curve: Curves.easeOutCubic,
        alignment: Alignment.topCenter,
        child: _expanded
            ? Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                if (kids.isEmpty)
                  SizedBox(
                    height: Sizes.control,
                    child: Padding(
                      padding: EdgeInsets.only(left: Gap.m + Gap.m + 16.0 * (widget.depth + 1) + 20),
                      child: Align(
                          alignment: Alignment.centerLeft,
                          child: Text('没有子页面', style: Theme.of(context).textTheme.bodySmall?.copyWith(color: c.text3))),
                    ),
                  ),
                for (final k in kids)
                  PageTreeTile(
                    key: ValueKey('page-tile-${k.id}'),
                    page: k,
                    depth: widget.depth + 1,
                    selected: widget.selected,
                    onSelect: widget.onSelect,
                  ),
              ])
            : const SizedBox(width: double.infinity),
      ),
    ]);
  }
}
