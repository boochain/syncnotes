import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../models/block.dart';
import '../pages/doc.dart';
import '../sync/sync_client.dart';
import 'ds.dart';
import 'home_page.dart' show ConnectionBadge;
import 'tokens.dart';

/// 侧边栏（布局照 AppFlowy / Notion）：顶部用户行 44，导航与页面树每行 32，分组标题行 32；
/// 选中 / 悬停都用中性灰叠加，不用强调色铺底。
class Sidebar extends StatelessWidget {
  final String? selectedPage; // null = 收件箱
  final bool inboxSelected;
  final bool settingsSelected;
  final void Function(String? pageId) onSelect;
  final VoidCallback onSearch;
  final VoidCallback onSettings;
  final bool trashSelected;
  final VoidCallback? onTrash;
  final bool transfersSelected;
  final VoidCallback? onTransfers;
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
    this.transfersSelected = false,
    this.onTransfers,
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
          listenable: Listenable.merge([s.sync, s.transfers]),
          builder: (context, _) {
            final roots = rootPages(s.sync);
            final name = s.settings.username ?? '';
            return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              SizedBox(
                key: const Key('sidebarHeader'),
                height: Sizes.bar,
                child: Padding(
                  padding: const EdgeInsets.only(left: Gap.xl, right: Gap.xl),
                  child: Row(children: [
                    Container(
                      width: Sizes.iconMd,
                      height: Sizes.iconMd,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(color: c.accent, borderRadius: BorderRadius.circular(AppRadius.s)),
                      child: Text(name.isEmpty ? '?' : name.characters.first.toUpperCase(),
                          textScaler: TextScaler.noScaling,
                          style: const TextStyle(fontSize: 12, height: 1.0, fontWeight: FontWeight.w600, color: Colors.white)),
                    ),
                    const SizedBox(width: Gap.m),
                    Expanded(child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: tt.labelLarge)),
                    const SizedBox(width: Gap.xs),
                    ConnectionBadge(sync: s.sync, dotOnly: true),
                  ]),
                ),
              ),
              SidebarRow(
                key: const Key('sidebarSearch'),
                leading: const Icon(CupertinoIcons.search),
                label: '搜索',
                trailing: Text('Ctrl K', maxLines: 1, style: tt.bodySmall?.copyWith(color: c.text3)),
                onTap: onSearch,
              ),
              SidebarRow(
                key: const Key('sidebarInbox'),
                leading: const Icon(CupertinoIcons.tray),
                label: '收件箱',
                selected: inboxSelected,
                trailing: s.sync.unreadCount > 0 ? CountBadge(s.sync.unreadCount) : null,
                onTap: () => onSelect(null),
              ),
              SidebarRow(
                key: const Key('sidebarSettings'),
                leading: const Icon(CupertinoIcons.gear),
                label: '设置',
                selected: settingsSelected,
                onTap: onSettings,
              ),
              if (onTrash != null)
                SidebarRow(
                  key: const Key('sidebarTrash'),
                  leading: const Icon(CupertinoIcons.trash),
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
                  leading: const Icon(CupertinoIcons.arrow_up_arrow_down),
                  label: '传输',
                  selected: transfersSelected,
                  trailing: s.transfers.activeCount > 0 ? CountBadge(s.transfers.activeCount) : null,
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
      onEnter: (e) { if (isMouseHover(e)) setState(() => _hover = true); },
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
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
      payload: {'icon': '📄', 'order': DocController.nextRootOrder(sync, parent)},
      parentId: parent,
      viewedMode: ViewedMode.global,
    )
    .id;

/// 页面树节点：展开 / 收起、悬停新建子页面、拖动排序（拖到行的上 / 下沿 → 前 / 后；中间 → 成为子页面）
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

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final c = AppColors.of(context);
    final kids = childPages(s.sync, widget.page.id);
    final sel = widget.selected == widget.page.id;
    final icon = (widget.page.payload['icon'] ?? '📄') as String;
    final title = widget.page.title.isEmpty ? '无标题' : widget.page.title;
    final indent = 16.0 * widget.depth; // AppFlowy HomeSpaceViewSizes.leftPadding 16
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
              decoration: BoxDecoration(color: c.elevated, borderRadius: BorderRadius.circular(AppRadius.s), border: Border.all(color: c.separator)),
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
