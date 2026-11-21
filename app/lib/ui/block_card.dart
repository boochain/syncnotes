import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_scope.dart';
import '../blocks/block_type.dart';
import '../models/block.dart';
import '../platform/desktop.dart';
import '../sync/sync_client.dart';
import 'context_menu.dart';
import 'ds.dart';
import 'glass.dart';
import 'tokens.dart';

String relTime(int ms) {
  final d = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(ms));
  if (d.inSeconds < 60) return '刚刚';
  if (d.inMinutes < 60) return '${d.inMinutes} 分钟前';
  if (d.inHours < 24) return '${d.inHours} 小时前';
  if (d.inDays < 7) return '${d.inDays} 天前';
  final t = DateTime.fromMillisecondsSinceEpoch(ms);
  return '${t.month}月${t.day}日';
}

/// 模拟便利贴风格的液态玻璃卡片（网格视图使用）：
/// - 顶部镜面高光条 + 毛玻璃透光 + 柔和类型色微染
/// - 多行摘要展示、底部同步云状态、悬停快捷操作与桌面端右键光标上下文菜单
class StickyNoteCard extends StatefulWidget {
  final Block block;
  const StickyNoteCard({super.key, required this.block});

  @override
  State<StickyNoteCard> createState() => _StickyNoteCardState();
}

class _StickyNoteCardState extends State<StickyNoteCard> {
  bool _hover = false;

  void _moveToTrash(BuildContext context) {
    final s = AppScope.of(context);
    final block = widget.block;
    final type = BlockTypes.of(block.kind);
    final messenger = ScaffoldMessenger.maybeOf(context);
    final ids = s.sync.delete(block.id);
    showToast(
      context,
      '已移到回收站：“${block.title.isEmpty ? type.label : block.title}”',
      messenger: messenger,
      actionLabel: '撤销',
      onAction: () => s.sync.restoreAll(ids),
    );
  }

  Color? _kindTint(BlockKind kind) => switch (kind) {
        BlockKind.folder => const Color(0xFFF59E0B),
        BlockKind.file => const Color(0xFF38BDF8),
        BlockKind.page || BlockKind.note || BlockKind.text => const Color(0xFFA855F7),
        BlockKind.message || BlockKind.unknown => null,
      };

  @override
  Widget build(BuildContext context) {
    final block = widget.block;
    final s = AppScope.of(context);
    final c = AppColors.of(context);
    final tt = Theme.of(context).textTheme;
    final type = BlockTypes.of(block.kind);
    final unread = !block.isViewed && block.kind != BlockKind.folder;
    final emoji = block.kind == BlockKind.page
        ? (block.payload['icon'] ?? '') as String
        : block.kind == BlockKind.folder
            ? (block.payload['icon'] ?? 'folder') as String
            : '';

    String bodyText;
    if (block.kind == BlockKind.message) {
      bodyText = ((block.payload['text'] ?? '') as String).trim();
    } else if (block.kind == BlockKind.note) {
      bodyText = ((block.payload['markdown'] ?? '') as String).trim();
    } else {
      bodyText = type.previewText(context, block).trim();
    }
    if (bodyText.isEmpty) bodyText = type.label;

    return Semantics(
      button: true,
      label: '${block.title}，$bodyText${unread ? '，未读' : ''}',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (e) {
          if (isMouseHover(e)) setState(() => _hover = true);
        },
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => type.execute(context, block),
          onLongPress: () {
            Feedback.forLongPress(context);
            showBlockMenu(context, block);
          },
          onSecondaryTapUp: (d) => showBlockMenu(context, block, anchor: d.globalPosition),
          child: SpecularGlassCard(
            key: ValueKey('card-${block.id}'),
            radius: 18,
            hover: _hover,
            tintAccent: _kindTint(block.kind),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Container(
                        width: 24,
                        height: 24,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: c.fill.withValues(alpha: 0.72),
                          borderRadius: BorderRadius.circular(AppRadius.s),
                        ),
                        child: emoji.isNotEmpty
                            ? Emoji(emoji, size: 15)
                            : Icon(type.icon, size: 13, color: c.text2),
                      ),
                      const SizedBox(width: Gap.s),
                      Expanded(
                        child: Text(
                          block.title.isEmpty ? '无标题' : block.title,
                          key: const Key('cardTitle'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: tt.titleSmall?.copyWith(fontSize: 15, fontWeight: FontWeight.w600, color: c.text),
                        ),
                      ),
                      if (unread) ...[
                        const SizedBox(width: Gap.xs),
                        Container(
                          key: const Key('unreadDot'),
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(color: c.accent, shape: BoxShape.circle),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: Gap.m),
                  Expanded(
                    child: Text(
                      bodyText,
                      key: const Key('cardPreview'),
                      maxLines: 5,
                      overflow: TextOverflow.ellipsis,
                      style: tt.bodySmall?.copyWith(color: c.text2, fontSize: 13, height: 1.48),
                    ),
                  ),
                  const SizedBox(height: Gap.s),
                  Row(
                    children: [
                      Icon(
                        block.pending ? CupertinoIcons.cloud_upload : CupertinoIcons.cloud,
                        size: 13,
                        color: block.pending ? c.warning : c.text3,
                      ),
                      const SizedBox(width: 5),
                      Expanded(
                        child: Text(
                          relTime(block.updatedAt),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: tt.bodySmall?.copyWith(color: c.text3, fontSize: 11),
                        ),
                      ),
                      if (isDesktop && _hover) ...[
                        _CardHoverAction(
                          tooltip: block.isViewed ? '标为未读' : '标为已读',
                          icon: block.isViewed ? CupertinoIcons.circle : CupertinoIcons.checkmark_circle,
                          onPressed: () => s.sync.setViewed(block.id, !block.isViewed),
                        ),
                        _CardHoverAction(
                          tooltip: '编辑',
                          icon: CupertinoIcons.pencil,
                          onPressed: () => type.edit(context, block),
                        ),
                        _CardHoverAction(
                          tooltip: '移入回收站',
                          icon: CupertinoIcons.trash,
                          danger: true,
                          onPressed: () => _moveToTrash(context),
                        ),
                      ],
                      Builder(
                        builder: (btnCtx) => SizedBox.square(
                          dimension: Sizes.compact,
                          child: IconButton(
                            key: const Key('cardMore'),
                            style: IconButton.styleFrom(
                              fixedSize: const Size.square(Sizes.compact),
                              minimumSize: const Size.square(Sizes.compact),
                              padding: EdgeInsets.zero,
                            ),
                            iconSize: Sizes.iconSm,
                            icon: Icon(CupertinoIcons.ellipsis, color: c.text2),
                            tooltip: '更多',
                            onPressed: () {
                              Offset? anchor;
                              if (isDesktop && Glass.useShader) {
                                final box = btnCtx.findRenderObject() as RenderBox?;
                                if (box != null) anchor = box.localToGlobal(Offset(box.size.width, box.size.height + 4));
                              }
                              showBlockMenu(context, block, anchor: anchor);
                            },
                          ),
                        ),
                      ),
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

/// 收件箱 / 文件夹的列表行（普通列表视图）：
/// - 桌面端支持鼠标右键原生 Apple Liquid Glass 上下文菜单 + 悬停一键快捷操作（已读/编辑/删除）
/// - 移动端支持左滑移入回收站（带撤销提示，不与系统边缘返回冲突）与长按底部菜单
class BlockCard extends StatefulWidget {
  final Block block;
  const BlockCard({super.key, required this.block});
  @override
  State<BlockCard> createState() => _BlockCardState();
}

class _BlockCardState extends State<BlockCard> {
  bool _hover = false;

  void _moveToTrash(BuildContext context) {
    final s = AppScope.of(context);
    final block = widget.block;
    final type = BlockTypes.of(block.kind);
    final messenger = ScaffoldMessenger.maybeOf(context);
    final ids = s.sync.delete(block.id);
    showToast(
      context,
      '已移到回收站：“${block.title.isEmpty ? type.label : block.title}”',
      messenger: messenger,
      actionLabel: '撤销',
      onAction: () => s.sync.restoreAll(ids),
    );
  }

  @override
  Widget build(BuildContext context) {
    final block = widget.block;
    final s = AppScope.of(context);
    final c = AppColors.of(context);
    final tt = Theme.of(context).textTheme;
    final type = BlockTypes.of(block.kind);
    final unread = !block.isViewed && block.kind != BlockKind.folder;
    final emoji = block.kind == BlockKind.page
        ? (block.payload['icon'] ?? '') as String
        : block.kind == BlockKind.folder
            ? (block.payload['icon'] ?? 'folder') as String
            : '';
    var preview = type.previewText(context, block);
    if (preview.isEmpty) preview = type.label;

    final dark = Theme.of(context).brightness == Brightness.dark;
    final translucent = Glass.surfaceTranslucent;
    final cardBg = _hover
        ? (translucent ? c.elevated.withValues(alpha: dark ? 0.56 : 0.78) : c.hover)
        : (translucent ? c.elevated.withValues(alpha: dark ? 0.28 : 0.44) : Colors.transparent);

    final rowWidget = Semantics(
      button: true,
      label: '${block.title}，$preview${unread ? '，未读' : ''}',
      child: MouseRegion(
        onEnter: (e) {
          if (isMouseHover(e)) setState(() => _hover = true);
        },
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => type.execute(context, block),
          onLongPress: () {
            Feedback.forLongPress(context);
            showBlockMenu(context, block);
          },
          onSecondaryTapUp: (d) => showBlockMenu(context, block, anchor: d.globalPosition),
          child: AnimatedContainer(
            key: ValueKey('card-${block.id}'),
            duration: Motion.short2,
            curve: Curves.easeOutCubic,
            constraints: const BoxConstraints(minHeight: Sizes.listRow),
            margin: EdgeInsets.symmetric(horizontal: translucent ? Gap.xl : Gap.m, vertical: translucent ? 4 : 0),
            padding: const EdgeInsets.only(left: Gap.m, right: Gap.xs),
            decoration: BoxDecoration(
              color: cardBg,
              borderRadius: BorderRadius.circular(translucent ? AppRadius.l : AppRadius.m),
              border: translucent
                  ? Border.all(
                      color: _hover
                          ? (dark ? Colors.white.withValues(alpha: 0.28) : Colors.white.withValues(alpha: 0.92))
                          : (dark ? Colors.white.withValues(alpha: 0.12) : Colors.white.withValues(alpha: 0.65)),
                    )
                  : null,
              boxShadow: translucent
                  ? [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: dark ? 0.18 : 0.04),
                        blurRadius: 12,
                        offset: const Offset(0, 3),
                      ),
                    ]
                  : const [],
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
                  Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
                    Expanded(
                      child: Text(block.title.isEmpty ? '无标题' : block.title,
                          key: const Key('cardTitle'), maxLines: 1, overflow: TextOverflow.ellipsis, style: tt.labelLarge),
                    ),
                    if (block.pending) ...[
                      const SizedBox(width: Gap.s),
                      Tooltip(
                        message: '等待同步',
                        child: SizedBox(height: 20, child: Center(child: Icon(CupertinoIcons.cloud_upload, size: 12, color: c.text3))),
                      ),
                    ],
                    const SizedBox(width: Gap.m),
                    Text(relTime(block.updatedAt), maxLines: 1, style: tt.bodySmall?.copyWith(color: c.text3)),
                    SizedBox(
                      width: 16,
                      height: 20,
                      child: unread
                          ? Center(
                              child: Container(
                                key: const Key('unreadDot'),
                                width: 8,
                                height: 8,
                                decoration: BoxDecoration(color: c.accent, shape: BoxShape.circle),
                              ),
                            )
                          : null,
                    ),
                  ]),
                  const SizedBox(height: 2),
                  Text(preview, key: const Key('cardPreview'), maxLines: 1, overflow: TextOverflow.ellipsis, style: tt.bodySmall?.copyWith(color: c.text2)),
                ]),
              ),
              if (isDesktop && _hover) ...[
                _CardHoverAction(
                  tooltip: block.isViewed ? '标为未读' : '标为已读',
                  icon: block.isViewed ? CupertinoIcons.circle : CupertinoIcons.checkmark_circle,
                  onPressed: () => s.sync.setViewed(block.id, !block.isViewed),
                ),
                _CardHoverAction(
                  tooltip: '编辑',
                  icon: CupertinoIcons.pencil,
                  onPressed: () => type.edit(context, block),
                ),
                _CardHoverAction(
                  tooltip: '移入回收站',
                  icon: CupertinoIcons.trash,
                  danger: true,
                  onPressed: () => _moveToTrash(context),
                ),
              ],
              Builder(
                builder: (btnCtx) => TouchTarget(
                  size: Sizes.compact,
                  child: IconButton(
                    key: const Key('cardMore'),
                    style: IconButton.styleFrom(fixedSize: const Size.square(Sizes.compact), minimumSize: const Size.square(Sizes.compact)),
                    iconSize: Sizes.iconSm,
                    icon: Icon(CupertinoIcons.ellipsis, color: c.text2),
                    onPressed: () {
                      Offset? anchor;
                      if (isDesktop && Glass.useShader) {
                        final box = btnCtx.findRenderObject() as RenderBox?;
                        if (box != null) anchor = box.localToGlobal(Offset(box.size.width, box.size.height + 4));
                      }
                      showBlockMenu(context, block, anchor: anchor);
                    },
                    tooltip: '更多',
                  ),
                ),
              ),
            ]),
          ),
        ),
      ),
    );

    if (isDesktop) return rowWidget;

    // 移动端：左滑卡片快捷移入回收站（带触感与撤销，不占用屏幕边缘返回区）
    return Dismissible(
      key: ValueKey('dismiss-${block.id}'),
      direction: DismissDirection.endToStart,
      dismissThresholds: const {DismissDirection.endToStart: 0.35},
      background: Container(
        margin: EdgeInsets.symmetric(horizontal: translucent ? Gap.xl : Gap.m, vertical: translucent ? 4 : 0),
        padding: const EdgeInsets.only(right: Gap.xl),
        alignment: Alignment.centerRight,
        decoration: BoxDecoration(
          color: c.danger.withValues(alpha: 0.88),
          borderRadius: BorderRadius.circular(translucent ? AppRadius.l : AppRadius.m),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(CupertinoIcons.trash, size: Sizes.iconMd, color: Colors.white),
            SizedBox(width: Gap.xs),
            Text('删除', style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600)),
          ],
        ),
      ),
      onDismissed: (_) {
        HapticFeedback.mediumImpact();
        _moveToTrash(context);
      },
      child: rowWidget,
    );
  }
}

class _CardHoverAction extends StatelessWidget {
  final String tooltip;
  final IconData icon;
  final bool danger;
  final VoidCallback onPressed;
  const _CardHoverAction({
    required this.tooltip,
    required this.icon,
    this.danger = false,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Tooltip(
      message: tooltip,
      child: IconButton(
        style: IconButton.styleFrom(
          fixedSize: const Size.square(Sizes.compact),
          minimumSize: const Size.square(Sizes.compact),
          padding: EdgeInsets.zero,
        ),
        iconSize: Sizes.iconSm,
        icon: Icon(icon, color: danger ? c.danger : c.text2),
        onPressed: onPressed,
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
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: detail == null ? Sizes.bar : Sizes.listRow),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: Gap.l, vertical: Gap.xs),
          child: Row(children: [
            SizedBox(width: Sizes.iconMd, child: Icon(icon, size: Sizes.iconSm, color: danger ? c.danger : c.text2)),
            const SizedBox(width: Gap.l),
            Expanded(
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
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

/// 块的上下文菜单：桌面右键 / 传 anchor 时弹出光标跟随 Apple Liquid Glass 上下文菜单；移动端弹出底部表单。
Future<void> showBlockMenu(BuildContext context, Block block, {Offset? anchor}) async {
  final s = AppScope.of(context);
  final type = BlockTypes.of(block.kind);
  final extra = type.extraActions(context, block);
  final banned = s.sync.descendantIds(block.id)..add(block.id);
  final folders = s.sync.blocks
      .where((b) => b.kind == BlockKind.folder && !b.deleted && !banned.contains(b.id) && b.id != block.parentId)
      .toList();
  final messenger = ScaffoldMessenger.maybeOf(context);
  final title = block.title.isEmpty ? '无标题' : block.title;

  Future<void> moveToFolder() async {
    final target = await showDialog<String>(
      context: context,
      builder: (d) => SimpleDialog(
        title: const Text('移动到'),
        contentPadding: const EdgeInsets.fromLTRB(Gap.m, Gap.m, Gap.m, Gap.l),
        children: [
          MenuRow(icon: CupertinoIcons.tray, label: '收件箱（根目录）', onTap: () => Navigator.pop(d, '__root__')),
          for (final f in folders)
            MenuRow(
              icon: CupertinoIcons.folder,
              label: f.title.isEmpty ? '无标题' : f.title,
              onTap: () => Navigator.pop(d, f.id),
            ),
        ],
      ),
    );
    if (target == null) return;
    if (target == '__root__') {
      s.sync.update(block.id, moveToRoot: true);
    } else {
      s.sync.update(block.id, parentId: target);
    }
  }

  void deleteBlock() {
    final ids = s.sync.delete(block.id);
    showToast(
      context,
      '已移到回收站：“${block.title.isEmpty ? type.label : block.title}”',
      messenger: messenger,
      actionLabel: '撤销',
      onAction: () => s.sync.restoreAll(ids),
    );
  }

  if (anchor != null) {
    await showGlassContextMenu(
      context,
      anchor: anchor,
      header: title,
      items: [
        ContextMenuItem(icon: type.icon, label: type.executeLabel, onTap: () => type.execute(context, block)),
        ContextMenuItem(icon: CupertinoIcons.pencil, label: '编辑', onTap: () => type.edit(context, block)),
        for (final a in extra) ContextMenuItem(icon: a.icon, label: a.label, onTap: a.run),
        const ContextMenuDivider(),
        ContextMenuItem(
          icon: block.isViewed ? CupertinoIcons.circle_fill : CupertinoIcons.checkmark_circle,
          label: block.isViewed ? '标为未读' : '标为已读',
          onTap: () => s.sync.setViewed(block.id, !block.isViewed),
        ),
        ContextMenuItem(
          icon: CupertinoIcons.device_laptop,
          label: '全局已读',
          checked: block.viewedMode == ViewedMode.global,
          onTap: () => s.sync.update(
            block.id,
            viewedMode: block.viewedMode == ViewedMode.global ? ViewedMode.perDevice : ViewedMode.global,
          ),
        ),
        ContextMenuItem(icon: CupertinoIcons.folder, label: '移动到…', onTap: moveToFolder),
        const ContextMenuDivider(),
        ContextMenuItem(
          key: const Key('menuDelete'),
          icon: CupertinoIcons.trash,
          label: '删除',
          danger: true,
          onTap: deleteBlock,
        ),
      ],
    );
    return;
  }

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
            child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: tt.titleMedium),
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
            trailing: AppSwitch(
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
            onTap: () {
              Navigator.pop(c);
              moveToFolder();
            },
          ),
          const Divider(height: Gap.l),
          MenuRow(key: const Key('menuDelete'), icon: CupertinoIcons.trash, label: '删除', danger: true, onTap: () {
            Navigator.pop(c);
            deleteBlock();
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

/// 动画块列表（支持模拟便利贴玻璃卡片网格视图与普通紧凑列表视图自由切换）。
class BlockList extends StatelessWidget {
  final String? parentId;
  final String filter;

  /// 只显示这些类型（null = 全部）
  final Set<BlockKind>? kinds;

  /// true = 模拟便利贴液态玻璃卡片网格；false = 普通单列列表
  final bool gridMode;
  final double topPadding;
  final double bottomPadding;
  const BlockList({
    super.key,
    this.parentId,
    this.filter = '',
    this.kinds,
    this.gridMode = false,
    this.topPadding = Gap.xs,
    this.bottomPadding = Gap.x3,
  });

  static final Set<String> _known = {};
  static var _ready = false;

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
        final fresh = [for (final b in items) if (!_known.contains(b.id)) b.id];
        final enterId = _ready && fresh.length == 1 ? fresh.single : null;
        if (enterId == null) {
          for (final b in sync.blocks) {
            _known.add(b.id);
          }
        } else {
          _known.add(enterId);
        }
        _ready = true;
        if (items.isEmpty) {
          return LayoutBuilder(
            builder: (context, c) => SingleChildScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: EdgeInsets.only(top: topPadding, bottom: bottomPadding),
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: (c.maxHeight - topPadding - bottomPadding).clamp(0.0, double.infinity)),
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

        if (gridMode) {
          return GridView.builder(
            key: const Key('blockGridView'),
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: EdgeInsets.fromLTRB(Gap.xl, topPadding, Gap.xl, bottomPadding),
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 268,
              mainAxisSpacing: 14,
              crossAxisSpacing: 14,
              childAspectRatio: 0.96,
            ),
            itemCount: items.length,
            itemBuilder: (context, i) {
              final card = StickyNoteCard(block: items[i]);
              if (items[i].id != enterId) return card;
              return _FadeIn(key: ValueKey('enter-${items[i].id}'), child: card);
            },
          );
        }

        return ListView.builder(
          key: const Key('blockListView'),
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          padding: EdgeInsets.only(top: topPadding, bottom: bottomPadding),
          itemCount: items.length,
          itemBuilder: (context, i) {
            final card = BlockCard(block: items[i]);
            if (items[i].id != enterId) return card;
            return _FadeIn(key: ValueKey('enter-${items[i].id}'), child: card);
          },
        );
      },
    );
  }
}

class _FadeIn extends StatefulWidget {
  final Widget child;
  const _FadeIn({super.key, required this.child});
  @override
  State<_FadeIn> createState() => _FadeInState();
}

class _FadeInState extends State<_FadeIn> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 220))..forward();
  late final CurvedAnimation _t = CurvedAnimation(parent: _c, curve: Curves.easeOutCubic);

  @override
  void dispose() {
    _t.dispose();
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _t,
      builder: (context, child) => Opacity(
        opacity: _t.value,
        child: Transform.translate(offset: Offset(0, (1 - _t.value) * 8), child: child),
      ),
      child: widget.child,
    );
  }
}

/// 新建块菜单：桌面传入 anchor 时弹出液态玻璃上下文菜单；移动端弹出底部表单。
Future<void> showCreateMenu(BuildContext context, {String? parentId, Offset? anchor}) async {
  if (anchor != null) {
    BlockType? picked;
    await showGlassContextMenu(
      context,
      anchor: anchor,
      header: '新建',
      items: [
        for (final t in BlockTypes.creatable)
          ContextMenuItem(
            key: Key('create-${t.kind.name}'),
            icon: t.icon,
            label: t.label,
            onTap: () => picked = t,
          ),
      ],
    );
    if (picked != null && context.mounted) await picked!.edit(context, null, parentId: parentId);
    return;
  }

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
