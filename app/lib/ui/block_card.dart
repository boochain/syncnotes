import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'ds.dart';
import 'tokens.dart';

import '../app_scope.dart';
import '../sync/sync_client.dart';
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

/// 收件箱 / 文件夹的列表行（照 Notion / AppFlowy 列表）：固定 56 高、两行（标题 + 单行摘要），
/// 左侧 28×28 中性图标底、右侧时间 / 未读点 / 更多按钮在第一行垂直居中；行间 1px 分隔线。
class BlockCard extends StatefulWidget {
  final Block block;
  const BlockCard({super.key, required this.block});
  @override
  State<BlockCard> createState() => _BlockCardState();
}

class _BlockCardState extends State<BlockCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final block = widget.block;
    final c = AppColors.of(context);
    final tt = Theme.of(context).textTheme;
    final type = BlockTypes.of(block.kind);
    final unread = !block.isViewed && block.kind != BlockKind.folder;
    final emoji = block.kind == BlockKind.page ? (block.payload['icon'] ?? '') as String : '';
    var preview = type.previewText(context, block);
    if (preview.isEmpty) preview = type.label;
    return Semantics(
      button: true,
      label: '${block.title}，$preview${unread ? '，未读' : ''}',
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => type.execute(context, block),
          onLongPress: () => showBlockMenu(context, block),
          onSecondaryTap: () => showBlockMenu(context, block),
          child: AnimatedContainer(
            key: ValueKey('card-${block.id}'),
            duration: Motion.short2,
            height: Sizes.listRow,
            margin: const EdgeInsets.symmetric(horizontal: Gap.m),
            padding: const EdgeInsets.only(left: Gap.m, right: Gap.xs),
            decoration: BoxDecoration(
              color: _hover ? c.hover : Colors.transparent,
              borderRadius: BorderRadius.circular(AppRadius.m),
            ),
            child: Row(children: [
              Container(
                width: Sizes.tile,
                height: Sizes.tile,
                alignment: Alignment.center,
                decoration: BoxDecoration(color: c.fill, borderRadius: BorderRadius.circular(AppRadius.s)),
                child: emoji.isNotEmpty ? Emoji(emoji, size: Sizes.iconMd) : Icon(type.icon, size: Sizes.iconSm, color: c.text2),
              ),
              const SizedBox(width: Gap.l),
              Expanded(
                child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Row(children: [
                    Expanded(
                      child: Text(block.title.isEmpty ? '无标题' : block.title,
                          key: const Key('cardTitle'), maxLines: 1, overflow: TextOverflow.ellipsis, style: tt.labelLarge),
                    ),
                    if (block.pending) ...[
                      const SizedBox(width: Gap.s),
                      Tooltip(message: '等待同步', child: Icon(CupertinoIcons.cloud_upload, size: 12, color: c.text3)),
                    ],
                    const SizedBox(width: Gap.m),
                    Text(relTime(block.updatedAt), maxLines: 1, style: tt.bodySmall?.copyWith(color: c.text3)),
                    SizedBox(
                      width: 16,
                      child: unread
                          ? Center(child: Container(key: const Key('unreadDot'), width: 8, height: 8, decoration: BoxDecoration(color: c.accent, shape: BoxShape.circle)))
                          : null,
                    ),
                  ]),
                  const SizedBox(height: 2),
                  Text(preview, key: const Key('cardPreview'), maxLines: 1, overflow: TextOverflow.ellipsis, style: tt.bodySmall?.copyWith(color: c.text2)),
                ]),
              ),
              SizedBox.square(
                dimension: Sizes.compact,
                child: IconButton(
                  key: const Key('cardMore'),
                  style: IconButton.styleFrom(fixedSize: const Size.square(Sizes.compact), minimumSize: const Size.square(Sizes.compact)),
                  iconSize: Sizes.iconSm,
                  icon: Icon(CupertinoIcons.ellipsis, color: c.text2),
                  onPressed: () => showBlockMenu(context, block),
                  tooltip: '更多',
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// 菜单行：固定 44 高（触屏也够点），图标 16 + 文字 14；危险操作用红色
class MenuRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String? detail;
  final bool danger;
  final Widget? trailing;
  final VoidCallback? onTap;
  const MenuRow({super.key, required this.icon, required this.label, this.detail, this.danger = false, this.trailing, this.onTap});
  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final tt = Theme.of(context).textTheme;
    final color = danger ? c.danger : c.text;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.s),
      child: SizedBox(
        height: Sizes.bar,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: Gap.l),
          child: Row(children: [
            SizedBox(width: Sizes.iconMd, child: Icon(icon, size: Sizes.iconSm, color: danger ? c.danger : c.text2)),
            const SizedBox(width: Gap.l),
            Expanded(
              child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: tt.bodyMedium?.copyWith(color: color)),
                if (detail != null) Text(detail!, maxLines: 1, overflow: TextOverflow.ellipsis, style: tt.bodySmall),
              ]),
            ),
            ?trailing,
          ]),
        ),
      ),
    );
  }
}

/// 块的上下文菜单（底部弹窗）
Future<void> showBlockMenu(BuildContext context, Block block) async {
  final s = AppScope.of(context);
  final type = BlockTypes.of(block.kind);
  final extra = type.extraActions(context, block);
  final banned = s.sync.descendantIds(block.id)..add(block.id);
  final folders = s.sync.blocks.where((b) => b.kind == BlockKind.folder && !b.deleted && !banned.contains(b.id) && b.id != block.parentId).toList();
  final tt = Theme.of(context).textTheme;
  await showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    constraints: const BoxConstraints(maxWidth: 520),
    builder: (c) => SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(Gap.m, 0, Gap.m, Gap.m),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.l, 0, Gap.l, Gap.m),
            child: Text(block.title.isEmpty ? '无标题' : block.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: tt.titleMedium),
          ),
          MenuRow(icon: type.icon, label: type.executeLabel, onTap: () {
            Navigator.pop(c);
            type.execute(context, block);
          }),
          MenuRow(icon: CupertinoIcons.pencil, label: '编辑', onTap: () {
            Navigator.pop(c);
            type.edit(context, block);
          }),
          for (final a in extra)
            MenuRow(icon: a.icon, label: a.label, onTap: () {
              Navigator.pop(c);
              a.run();
            }),
          MenuRow(
            icon: block.isViewed ? CupertinoIcons.circle_fill : CupertinoIcons.checkmark_circle,
            label: block.isViewed ? '标为未读' : '标为已读',
            onTap: () {
              Navigator.pop(c);
              s.sync.setViewed(block.id, !block.isViewed);
            },
          ),
          MenuRow(
            icon: CupertinoIcons.device_laptop,
            label: '全局已读',
            detail: block.viewedMode == ViewedMode.global ? '在任一设备查看后，所有设备都标为已读' : '每台设备独立记录已读状态',
            trailing: Switch(
              value: block.viewedMode == ViewedMode.global,
              onChanged: (v) {
                Navigator.pop(c);
                s.sync.update(block.id, viewedMode: v ? ViewedMode.global : ViewedMode.perDevice);
              },
            ),
          ),
          MenuRow(
            icon: CupertinoIcons.folder,
            label: '移动到…',
            onTap: () async {
              Navigator.pop(c);
              final target = await showDialog<String>(
                context: context,
                builder: (d) => SimpleDialog(
                  title: const Text('移动到'),
                  contentPadding: const EdgeInsets.fromLTRB(Gap.m, Gap.m, Gap.m, Gap.l),
                  children: [
                    MenuRow(icon: CupertinoIcons.tray, label: '收件箱（根目录）', onTap: () => Navigator.pop(d, '__root__')),
                    for (final f in folders)
                      MenuRow(icon: CupertinoIcons.folder, label: f.title.isEmpty ? '无标题' : f.title, onTap: () => Navigator.pop(d, f.id)),
                  ],
                ),
              );
              if (target == null) return;
              if (target == '__root__') {
                s.sync.update(block.id, moveToRoot: true);
              } else {
                s.sync.update(block.id, parentId: target);
              }
            },
          ),
          const Divider(height: Gap.l),
          MenuRow(icon: CupertinoIcons.trash, label: '删除', danger: true, onTap: () {
            Navigator.pop(c);
            s.sync.delete(block.id);
          }),
        ]),
      ),
    ),
  );
}

/// 空状态 / 加载 / 错误统一样式：20 号图标（28 底）+ 标题 16/600 + 说明 12
class EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? action;
  const EmptyState({super.key, required this.icon, required this.title, this.subtitle, this.action});
  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final tt = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.all(Gap.x3),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: Sizes.bar,
          height: Sizes.bar,
          decoration: BoxDecoration(color: c.fill, borderRadius: BorderRadius.circular(AppRadius.l)),
          child: Icon(icon, size: Sizes.iconMd, color: c.text2),
        ),
        const SizedBox(height: Gap.l),
        Text(title, textAlign: TextAlign.center, style: tt.titleMedium),
        if (subtitle != null) ...[
          const SizedBox(height: Gap.xs),
          Text(subtitle!, textAlign: TextAlign.center, style: tt.bodySmall),
        ],
        if (action != null) ...[const SizedBox(height: Gap.xl), action!],
      ]),
    );
  }
}

/// 动画块列表。
class BlockList extends StatelessWidget {
  final String? parentId;
  final String filter;

  /// 只显示这些类型（null = 全部）
  final Set<BlockKind>? kinds;
  const BlockList({super.key, this.parentId, this.filter = '', this.kinds});

  @override
  Widget build(BuildContext context) {
    final sync = AppScope.of(context).sync;
    return ListenableBuilder(
      listenable: sync,
      builder: (context, _) {
        var items = filter.isEmpty
            ? sync.childrenOf(parentId)
            : sync.blocks.where((b) {
                if (!SyncClient.isInboxItem(b)) return false;
                final q = filter.toLowerCase();
                return b.title.toLowerCase().contains(q) ||
                    b.payload.values.whereType<String>().any((v) => v.toLowerCase().contains(q));
              }).toList();
        if (kinds != null) items = items.where((b) => kinds!.contains(b.kind)).toList();
        // 文件夹置顶
        items = [
          ...items.where((b) => b.kind == BlockKind.folder),
          ...items.where((b) => b.kind != BlockKind.folder),
        ];
        if (items.isEmpty) {
          return LayoutBuilder(
            builder: (context, c) => SingleChildScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: c.maxHeight),
                child: Center(
                  child: EmptyState(
                    key: const Key('emptyState'),
                    icon: filter.isEmpty ? CupertinoIcons.tray : CupertinoIcons.search,
                    title: filter.isEmpty ? '这里还没有内容' : '没有匹配的结果',
                    subtitle: filter.isEmpty ? '在下方输入框发送消息，或点击 + 新建页面、文件、文件夹' : '换个关键词试试',
                  ),
                ),
              ),
            ),
          );
        }
        return ListView.builder(
          padding: const EdgeInsets.only(top: Gap.xs, bottom: Gap.x3),
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

/// 新建块菜单（底部弹出）：和上下文菜单同样的 44 高菜单行
Future<void> showCreateMenu(BuildContext context, {String? parentId}) async {
  final t = await showModalBottomSheet<BlockType>(
    context: context,
    constraints: const BoxConstraints(maxWidth: 520),
    builder: (c) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Gap.m, 0, Gap.m, Gap.m),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.l, 0, Gap.l, Gap.m),
            child: Text('新建', style: Theme.of(c).textTheme.titleMedium),
          ),
          for (final t in BlockTypes.creatable)
            MenuRow(key: Key('create-${t.kind.name}'), icon: t.icon, label: t.label, onTap: () => Navigator.pop(c, t)),
        ]),
      ),
    ),
  );
  if (t != null && context.mounted) await t.edit(context, null, parentId: parentId);
}
