import 'package:flutter/material.dart';
import 'tokens.dart';

import '../app_scope.dart';
import '../models/block.dart';
import '../pages/doc.dart';
import '../sync/sync_client.dart';
import 'home_page.dart' show ConnectionBadge;

/// 侧边栏：收件箱、页面树（可展开、悬停新建子页面）、搜索入口、设置。
class Sidebar extends StatelessWidget {
  final String? selectedPage; // null = 收件箱
  final bool inboxSelected;
  final void Function(String? pageId) onSelect;
  final VoidCallback onSearch;
  final VoidCallback onSettings;
  const Sidebar({
    super.key,
    required this.selectedPage,
    required this.inboxSelected,
    required this.onSelect,
    required this.onSearch,
    required this.onSettings,
  });

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: Colors.transparent,
      child: SafeArea(
        right: false,
        child: ListenableBuilder(
          listenable: s.sync,
          builder: (context, _) {
            final roots = rootPages(s.sync);
            return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 8, 4),
                child: Row(children: [
                  CircleAvatar(
                    radius: 13,
                    backgroundColor: cs.primary,
                    child: Text((s.settings.username ?? '?').characters.first.toUpperCase(),
                        style: TextStyle(fontSize: 13, color: cs.onPrimary, fontWeight: FontWeight.w600)),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(s.settings.username ?? '', overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                  ),
                  ConnectionBadge(sync: s.sync),
                ]),
              ),
              const SizedBox(height: 6),
              _NavItem(
                key: const Key('sidebarSearch'),
                icon: Icons.search,
                label: '搜索',
                trailing: Text('Ctrl+K', style: TextStyle(fontSize: 11, color: cs.outline)),
                onTap: onSearch,
              ),
              _NavItem(
                key: const Key('sidebarInbox'),
                icon: Icons.inbox_outlined,
                label: '收件箱',
                selected: inboxSelected,
                trailing: s.sync.unreadCount > 0
                    ? Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                        decoration: BoxDecoration(color: cs.primary, borderRadius: BorderRadius.circular(10)),
                        child: Text('${s.sync.unreadCount}', style: TextStyle(fontSize: 11, color: cs.onPrimary)),
                      )
                    : null,
                onTap: () => onSelect(null),
              ),
              _NavItem(icon: Icons.settings_outlined, label: '设置', onTap: onSettings),
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 18, 8, 4),
                child: Row(children: [
                  Text('页面', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: cs.outline)),
                  const Spacer(),
                  IconButton(
                    key: const Key('newRootPage'),
                    tooltip: '新建页面',
                    visualDensity: VisualDensity.compact,
                    iconSize: 18,
                    icon: const Icon(Icons.add),
                    onPressed: () => onSelect(createPage(s.sync, null)),
                  ),
                ]),
              ),
              Expanded(
                child: roots.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.all(18),
                        child: Text('还没有页面，点击 + 新建', style: TextStyle(color: cs.outline, fontSize: 13)),
                      )
                    : ListView(
                        padding: const EdgeInsets.only(bottom: 12),
                        children: [
                          for (final p in roots)
                            PageTreeTile(page: p, depth: 0, selected: selectedPage, onSelect: (id) => onSelect(id)),
                        ],
                      ),
              ),
            ]);
          },
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

class _NavItem extends StatefulWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final Widget? trailing;
  final VoidCallback onTap;
  const _NavItem({super.key, required this.icon, required this.label, this.selected = false, this.trailing, required this.onTap});
  @override
  State<_NavItem> createState() => _NavItemState();
}

class _NavItemState extends State<_NavItem> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: Motion.short3,
          margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          decoration: BoxDecoration(
            color: widget.selected
                ? cs.primary.withValues(alpha: 0.12)
                : _hover
                    ? cs.onSurface.withValues(alpha: 0.05)
                    : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(children: [
            Icon(widget.icon, size: 18, color: widget.selected ? cs.primary : cs.onSurfaceVariant),
            const SizedBox(width: 10),
            Expanded(
              child: Text(widget.label,
                  style: TextStyle(fontSize: 14, color: widget.selected ? cs.primary : cs.onSurface, fontWeight: widget.selected ? FontWeight.w600 : null)),
            ),
            ?widget.trailing,
          ]),
        ),
      ),
    );
  }
}

/// 页面树节点
class PageTreeTile extends StatefulWidget {
  final Block page;
  final int depth;
  final String? selected;
  final void Function(String id) onSelect;
  const PageTreeTile({super.key, required this.page, required this.depth, required this.selected, required this.onSelect});
  @override
  State<PageTreeTile> createState() => _PageTreeTileState();
}

class _PageTreeTileState extends State<PageTreeTile> {
  bool _expanded = false;
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final cs = Theme.of(context).colorScheme;
    final kids = childPages(s.sync, widget.page.id);
    final sel = widget.selected == widget.page.id;
    final icon = (widget.page.payload['icon'] ?? '📄') as String;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: () => widget.onSelect(widget.page.id),
          child: AnimatedContainer(
            key: ValueKey('tree-${widget.page.id}'),
            duration: Motion.short3,
            margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
            padding: EdgeInsets.only(left: 4 + 14.0 * widget.depth, right: 4),
            height: 32,
            decoration: BoxDecoration(
              color: sel ? cs.primary.withValues(alpha: 0.12) : (_hover ? cs.onSurface.withValues(alpha: 0.05) : null),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(children: [
              InkWell(
                key: ValueKey('expand-${widget.page.id}'),
                borderRadius: BorderRadius.circular(4),
                onTap: () => setState(() => _expanded = !_expanded),
                child: SizedBox(
                  width: 22,
                  height: 22,
                  child: AnimatedRotation(
                    turns: _expanded ? 0.25 : 0,
                    duration: Motion.short4,
                    child: Icon(Icons.chevron_right, size: 16, color: kids.isEmpty ? cs.outlineVariant : cs.onSurfaceVariant),
                  ),
                ),
              ),
              const SizedBox(width: 2),
              Text(icon, style: const TextStyle(fontSize: 15)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(widget.page.title.isEmpty ? '无标题' : widget.page.title,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 14, fontWeight: sel ? FontWeight.w600 : null, color: sel ? cs.primary : cs.onSurface)),
              ),
              AnimatedOpacity(
                opacity: _hover ? 1 : 0,
                duration: Motion.short3,
                child: InkWell(
                  borderRadius: BorderRadius.circular(4),
                  onTap: () {
                    final id = createPage(s.sync, widget.page.id);
                    setState(() => _expanded = true);
                    widget.onSelect(id);
                  },
                  child: Tooltip(message: '新建子页面', child: Icon(Icons.add, size: 16, color: cs.outline)),
                ),
              ),
            ]),
          ),
        ),
      ),
      AnimatedSize(
        duration: Motion.short4,
        curve: Curves.easeOutCubic,
        alignment: Alignment.topCenter,
        child: _expanded
            ? Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                if (kids.isEmpty)
                  Padding(
                    padding: EdgeInsets.only(left: 46 + 14.0 * widget.depth, top: 4, bottom: 4),
                    child: Text('没有子页面', style: TextStyle(fontSize: 12, color: cs.outline)),
                  ),
                for (final k in kids)
                  PageTreeTile(page: k, depth: widget.depth + 1, selected: widget.selected, onSelect: widget.onSelect),
              ])
            : const SizedBox(width: double.infinity),
      ),
    ]);
  }
}
