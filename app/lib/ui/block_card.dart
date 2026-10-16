import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../blocks/block_type.dart';
import '../models/block.dart';

String relTime(int ms) {
  final d = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(ms));
  if (d.inSeconds < 60) return '刚刚';
  if (d.inMinutes < 60) return '${d.inMinutes} 分钟前';
  if (d.inHours < 24) return '${d.inHours} 小时前';
  if (d.inDays < 7) return '${d.inDays} 天前';
  final t = DateTime.fromMillisecondsSinceEpoch(ms);
  return '${t.month}月${t.day}日';
}

class BlockCard extends StatelessWidget {
  final Block block;
  const BlockCard({super.key, required this.block});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final type = BlockTypes.of(block.kind);
    final unread = !block.isViewed && block.kind != BlockKind.folder;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Card(
        elevation: unread ? 2 : 0,
        color: unread ? cs.surfaceContainerHigh : cs.surfaceContainerLow,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: unread ? cs.primary.withValues(alpha: 0.5) : Colors.transparent),
        ),
        child: InkWell(
          onTap: () => type.execute(context, block),
          onLongPress: () => _menu(context, type),
          onSecondaryTap: () => _menu(context, type),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 6, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  CircleAvatar(
                    radius: 14,
                    backgroundColor: type.color(cs).withValues(alpha: 0.18),
                    child: Icon(type.icon, size: 16, color: type.color(cs)),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(block.title.isEmpty ? '(无标题)' : block.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                            fontWeight: unread ? FontWeight.w700 : FontWeight.w500)),
                  ),
                  if (block.pending)
                    Tooltip(
                        message: '等待同步',
                        child: Icon(Icons.cloud_upload_outlined, size: 16, color: cs.outline)),
                  if (block.viewedMode == ViewedMode.global)
                    Padding(
                      padding: const EdgeInsets.only(left: 4),
                      child: Tooltip(
                          message: '全局已读模式',
                          child: Icon(Icons.public, size: 14, color: cs.outline)),
                    ),
                  AnimatedScale(
                    scale: unread ? 1 : 0,
                    duration: const Duration(milliseconds: 200),
                    child: Container(
                      margin: const EdgeInsets.only(left: 6),
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(color: cs.primary, shape: BoxShape.circle),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Text(relTime(block.updatedAt),
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(color: cs.outline)),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.more_vert, size: 18),
                    onPressed: () => _menu(context, type),
                    tooltip: '更多',
                  ),
                ]),
                const SizedBox(height: 6),
                Padding(
                  padding: const EdgeInsets.only(left: 38, right: 8),
                  child: type.buildPreview(context, block),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _menu(BuildContext context, BlockType type) async {
    final s = AppScope.of(context);
    final extra = type.extraActions(context, block);
    final banned = s.sync.descendantIds(block.id)..add(block.id);
    final folders = s.sync.blocks
        .where((b) => b.kind == BlockKind.folder && !banned.contains(b.id) && b.id != block.parentId)
        .toList();
    await showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            ListTile(
              leading: Icon(type.icon),
              title: Text(type.executeLabel),
              onTap: () {
                Navigator.pop(c);
                type.execute(context, block);
              },
            ),
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('编辑'),
              onTap: () {
                Navigator.pop(c);
                type.edit(context, block);
              },
            ),
            for (final a in extra)
              ListTile(
                leading: Icon(a.icon),
                title: Text(a.label),
                onTap: () {
                  Navigator.pop(c);
                  a.run();
                },
              ),
            ListTile(
              leading: Icon(block.isViewed ? Icons.mark_email_unread_outlined : Icons.done_all),
              title: Text(block.isViewed ? '标为未读' : '标为已读'),
              onTap: () {
                Navigator.pop(c);
                s.sync.setViewed(block.id, !block.isViewed);
              },
            ),
            SwitchListTile(
              secondary: const Icon(Icons.public),
              title: const Text('全局已读'),
              subtitle: Text(block.viewedMode == ViewedMode.global
                  ? '在任一设备查看后，所有设备都标为已读'
                  : '每台设备独立记录已读状态'),
              value: block.viewedMode == ViewedMode.global,
              onChanged: (v) {
                Navigator.pop(c);
                s.sync.update(block.id, viewedMode: v ? ViewedMode.global : ViewedMode.perDevice);
              },
            ),
            ListTile(
              leading: const Icon(Icons.drive_file_move_outline),
              title: const Text('移动到…'),
              onTap: () async {
                Navigator.pop(c);
                final target = await showDialog<String>(
                  context: context,
                  builder: (d) => SimpleDialog(title: const Text('移动到'), children: [
                    SimpleDialogOption(
                        onPressed: () => Navigator.pop(d, '__root__'), child: const Text('📥 根目录')),
                    for (final f in folders)
                      SimpleDialogOption(
                          onPressed: () => Navigator.pop(d, f.id), child: Text('📁 ${f.title}')),
                  ]),
                );
                if (target == null) return;
                if (target == '__root__') {
                  s.sync.update(block.id, moveToRoot: true);
                } else {
                  s.sync.update(block.id, parentId: target);
                }
              },
            ),
            ListTile(
              leading: Icon(Icons.delete_outline, color: Theme.of(context).colorScheme.error),
              title: Text('删除', style: TextStyle(color: Theme.of(context).colorScheme.error)),
              onTap: () {
                Navigator.pop(c);
                s.sync.delete(block.id);
              },
            ),
          ]),
        ),
      ),
    );
  }
}

/// 动画块列表。
class BlockList extends StatelessWidget {
  final String? parentId;
  final String filter;
  const BlockList({super.key, this.parentId, this.filter = ''});

  @override
  Widget build(BuildContext context) {
    final sync = AppScope.of(context).sync;
    return ListenableBuilder(
      listenable: sync,
      builder: (context, _) {
        var items = filter.isEmpty
            ? sync.childrenOf(parentId)
            : sync.blocks.where((b) {
                final q = filter.toLowerCase();
                return b.title.toLowerCase().contains(q) ||
                    b.payload.values.whereType<String>().any((v) => v.toLowerCase().contains(q));
              }).toList();
        // 文件夹置顶
        items = [
          ...items.where((b) => b.kind == BlockKind.folder),
          ...items.where((b) => b.kind != BlockKind.folder),
        ];
        if (items.isEmpty) {
          return Center(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.inbox_outlined, size: 56, color: Theme.of(context).colorScheme.outlineVariant),
              const SizedBox(height: 8),
              Text(filter.isEmpty ? '这里还没有内容' : '没有匹配的结果',
                  style: TextStyle(color: Theme.of(context).colorScheme.outline)),
            ]),
          );
        }
        return ListView.builder(
          padding: const EdgeInsets.only(top: 4, bottom: 96),
          itemCount: items.length,
          itemBuilder: (context, i) => TweenAnimationBuilder<double>(
            key: ValueKey(items[i].id),
            tween: Tween(begin: 0, end: 1),
            duration: Duration(milliseconds: 220 + (i.clamp(0, 8) * 30)),
            curve: Curves.easeOutCubic,
            builder: (context, t, child) => Opacity(
              opacity: t,
              child: Transform.translate(offset: Offset(0, (1 - t) * 12), child: child),
            ),
            child: BlockCard(block: items[i]),
          ),
        );
      },
    );
  }
}

/// 新建块菜单（底部弹出）。
Future<void> showCreateMenu(BuildContext context, {String? parentId}) async {
  final cs = Theme.of(context).colorScheme;
  final t = await showModalBottomSheet<BlockType>(
    context: context,
    showDragHandle: true,
    builder: (c) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Wrap(spacing: 12, runSpacing: 12, children: [
          for (final t in BlockTypes.creatable)
            SizedBox(
              width: 100,
              child: FilledButton.tonal(
                style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
                onPressed: () => Navigator.pop(c, t),
                child: Column(children: [
                  Icon(t.icon, color: t.color(cs)),
                  const SizedBox(height: 6),
                  Text(t.label),
                ]),
              ),
            ),
        ]),
      ),
    ),
  );
  if (t != null && context.mounted) await t.edit(context, null, parentId: parentId);
}
