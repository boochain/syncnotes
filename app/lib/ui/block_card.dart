import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_scope.dart';
import '../blocks/block_type.dart';
import '../models/block.dart';
import '../platform/desktop.dart';
import '../sync/sync_client.dart';
import '../tasks/task_actions.dart';
import '../tasks/task_models.dart';
import 'context_menu.dart';
import 'ds.dart';
import 'glass.dart';
import 'motion.dart';
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

/// 便签优先级与颜色预设（同步保存在 `block.payload['sticky_color']`）。
/// 排序时按 `priority` 从高到低排列（紧急 > 重要 > 待办 > 灵感 > 备忘 > 默认）。
class StickyColorOption {
  final String key;
  final String label;
  final String tag;
  final Color? color;
  final int priority;
  const StickyColorOption(this.key, this.label, this.tag, this.color, this.priority);
}

const stickyColorOptions = <StickyColorOption>[
  StickyColorOption('red', '紧急 · 珊瑚红（最高优先级）', '紧急', Color(0xFFEF4444), 5),
  StickyColorOption('amber', '重要 · 琥珀金（高优先级）', '重要', Color(0xFFF59E0B), 4),
  StickyColorOption('blue', '待办 · 晴空蓝（中优先级）', '待办', Color(0xFF3B82F6), 3),
  StickyColorOption('purple', '灵感 · 薰衣草（低优先级）', '灵感', Color(0xFFA855F7), 2),
  StickyColorOption('green', '备忘 · 翡翠绿', '备忘', Color(0xFF10B981), 1),
  StickyColorOption('default', '默认 · 透明水晶', '', null, 0),
];

StickyColorOption stickyColorOf(Block block) {
  final key = block.payload['sticky_color'] as String? ?? 'default';
  for (final opt in stickyColorOptions) {
    if (opt.key == key) return opt;
  }
  return stickyColorOptions.last;
}

/// 块的优先级分值（越大越靠前）：优先读取显式 `priority` 数值，否则取便签重要级别颜色对应的优先级。
int blockPriorityOf(Block block) {
  final explicit = block.payload['priority'];
  if (explicit is num) return explicit.toInt();
  return stickyColorOf(block).priority;
}

/// 块是否已标记为完成（同步保存在 `block.payload['completed']`；任务还看 status）。
bool isBlockCompleted(Block block) {
  if (isTaskBlock(block)) return taskDataOf(block).status == TaskStatus.done;
  return block.payload['completed'] == true;
}

void setStickyColor(SyncClient sync, Block block, String colorKey) {
  final next = Map<String, dynamic>.from(block.payload);
  if (colorKey == 'default') {
    next.remove('sticky_color');
  } else {
    next['sticky_color'] = colorKey;
  }
  sync.update(block.id, payload: next);
}

void setBlockCompleted(SyncClient sync, Block block, bool completed) {
  if (isTaskBlock(block)) {
    setTaskCompleted(sync, block, completed);
    return;
  }
  final next = Map<String, dynamic>.from(block.payload);
  if (completed) {
    next['completed'] = true;
    next['completed_at'] = DateTime.now().millisecondsSinceEpoch;
  } else {
    next.remove('completed');
    next.remove('completed_at');
  }
  sync.update(block.id, payload: next);
}

/// 收件箱 / 文件夹统一排序规则：
/// 1. 完成状态：未完成永远在最前，已完成永远单独排在最后；
/// 2. 优先级（第一优先项）：紧急 > 重要 > 待办 > 灵感 > 备忘 > 默认；
/// 3. 同优先级下文件夹置前；
/// 4. 创建时间倒序（最新创建的在前），其次更新时间倒序、ID 稳定排序。
int compareInboxBlocks(Block a, Block b) {
  final ac = isBlockCompleted(a);
  final bc = isBlockCompleted(b);
  if (ac != bc) return ac ? 1 : -1;

  final pa = blockPriorityOf(a);
  final pb = blockPriorityOf(b);
  if (pa != pb) return pb.compareTo(pa);

  final af = a.kind == BlockKind.folder;
  final bf = b.kind == BlockKind.folder;
  if (af != bf) return af ? -1 : 1;

  final created = b.createdAt.compareTo(a.createdAt);
  if (created != 0) return created;
  final updated = b.updatedAt.compareTo(a.updatedAt);
  if (updated != 0) return updated;
  return a.id.compareTo(b.id);
}

/// 块完成状态圆形勾选按钮（列表与便签卡片共用）。
class _CompleteCheckButton extends StatelessWidget {
  final Block block;
  final double size;
  const _CompleteCheckButton({required this.block, this.size = 26});

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final c = AppColors.of(context);
    final done = isBlockCompleted(block);
    return Tooltip(
      message: done ? '取消完成' : '标为已完成',
      child: InkWell(
        key: ValueKey('completeToggle-${block.id}'),
        customBorder: const CircleBorder(),
        onTap: () {
          HapticFeedback.selectionClick();
          setBlockCompleted(s.sync, block, !done);
        },
        child: SizedBox.square(
          dimension: size,
          child: Center(
            child: AnimatedContainer(
              duration: Motion.short2,
              width: 18,
              height: 18,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: done ? c.success : Colors.transparent,
                border: Border.all(
                  color: done ? c.success : c.text3.withValues(alpha: 0.55),
                  width: 1.5,
                ),
              ),
              child: done ? const Icon(CupertinoIcons.checkmark, size: 11, color: Colors.white) : null,
            ),
          ),
        ),
      ),
    );
  }
}

/// “已完成”分组分隔标题（折叠/展开已完成区，始终位于未完成区之后）。
class _CompletedSectionHeader extends StatelessWidget {
  final int count;
  final bool expanded;
  final VoidCallback onToggle;
  final EdgeInsetsGeometry padding;
  const _CompletedSectionHeader({
    required this.count,
    required this.expanded,
    required this.onToggle,
    this.padding = const EdgeInsets.fromLTRB(Gap.xl, Gap.l, Gap.xl, Gap.s),
  });

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final tt = Theme.of(context).textTheme;
    return Padding(
      padding: padding,
      child: InkWell(
        key: const Key('completedSectionHeader'),
        borderRadius: BorderRadius.circular(AppRadius.m),
        onTap: onToggle,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: Gap.xs, vertical: Gap.xs),
          child: Row(
            children: [
              Icon(
                CupertinoIcons.checkmark_circle_fill,
                size: 14,
                color: c.success,
              ),
              const SizedBox(width: Gap.xs),
              Text(
                '已完成 · $count',
                style: tt.labelMedium?.copyWith(
                  color: c.text2,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: Gap.s),
              Expanded(child: Divider(height: 1, color: c.separator.withValues(alpha: 0.7))),
              const SizedBox(width: Gap.s),
              Icon(
                expanded ? CupertinoIcons.chevron_down : CupertinoIcons.chevron_right,
                size: 13,
                color: c.text3,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

double? _numField(Map<String, dynamic> payload, String key) {
  final v = payload[key];
  if (v is num) return v.toDouble();
  return null;
}

/// 弹出便签颜色 / 重要级别选择浮窗（支持桌面光标定位与移动端居中）。
Future<void> showStickyColorPicker(BuildContext context, Block block, {Offset? anchor}) async {
  final sync = AppScope.of(context).sync;
  final current = stickyColorOf(block).key;
  await showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: '选择便签颜色',
    barrierColor: Colors.transparent,
    transitionDuration: Motion.short3,
    pageBuilder: (ctx, a1, a2) {
      final size = MediaQuery.sizeOf(ctx);
      final c = AppColors.of(ctx);
      final tt = Theme.of(ctx).textTheme;
      const panelW = 248.0;
      const panelH = 122.0;
      double left = anchor != null ? anchor.dx - panelW / 2 : (size.width - panelW) / 2;
      double top = anchor != null ? anchor.dy + 8 : (size.height - panelH) / 2;
      left = left.clamp(12.0, math.max(12.0, size.width - panelW - 12.0));
      top = top.clamp(12.0, math.max(12.0, size.height - panelH - 12.0));

      return Stack(
        children: [
          Positioned(
            left: left,
            top: top,
            width: panelW,
            child: Glass(
              radius: 18,
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
              child: Material(
                type: MaterialType.transparency,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '优先级与颜色（按优先级排序）',
                      style: tt.labelMedium?.copyWith(color: c.text2, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final opt in stickyColorOptions)
                          _ColorSwatchChip(
                            option: opt,
                            selected: opt.key == current,
                            onTap: () {
                              setStickyColor(sync, block, opt.key);
                              Navigator.of(ctx).pop();
                            },
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      );
    },
    transitionBuilder: (ctx, animation, secondaryAnimation, child) =>
        MotionFade(animation: animation, child: child),
  );
}

class _ColorSwatchChip extends StatelessWidget {
  final StickyColorOption option;
  final bool selected;
  final VoidCallback onTap;
  const _ColorSwatchChip({required this.option, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final swatch = option.color;
    return Tooltip(
      message: option.label,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: AnimatedContainer(
          duration: Motion.short2,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
          decoration: BoxDecoration(
            color: selected
                ? (swatch ?? c.accent).withValues(alpha: dark ? 0.28 : 0.18)
                : c.fill.withValues(alpha: 0.48),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: selected ? (swatch ?? c.accent) : c.separator.withValues(alpha: 0.6),
              width: selected ? 1.5 : 1.0,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: swatch ?? (dark ? Colors.white.withValues(alpha: 0.28) : Colors.white.withValues(alpha: 0.9)),
                  border: Border.all(
                    color: swatch != null ? Colors.white.withValues(alpha: 0.7) : c.text3.withValues(alpha: 0.6),
                    width: 1,
                  ),
                ),
              ),
              const SizedBox(width: 5),
              Text(
                option.tag.isEmpty ? '默认' : option.tag,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      fontSize: 11.5,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                      color: c.text,
                    ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 模拟便利贴风格的液态玻璃卡片（支持自由拖拽抬升阴影、重要级别染色与右键菜单）。
class StickyNoteCard extends StatefulWidget {
  final Block block;
  final bool dragging;
  final VoidCallback? onBringToFront;
  const StickyNoteCard({
    super.key,
    required this.block,
    this.dragging = false,
    this.onBringToFront,
  });

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
        BlockKind.page || BlockKind.note => const Color(0xFF8B5CF6),
        BlockKind.task => const Color(0xFF007AFF),
        BlockKind.message || BlockKind.text || BlockKind.unknown => null,
      };

  @override
  Widget build(BuildContext context) {
    final block = widget.block;
    final s = AppScope.of(context);
    final c = AppColors.of(context);
    final tt = Theme.of(context).textTheme;
    final type = BlockTypes.of(block.kind);
    final unread = !block.isViewed && block.kind != BlockKind.folder;
    final completed = isBlockCompleted(block);
    final stickyColor = stickyColorOf(block);
    final effectiveTint = completed ? c.success : (stickyColor.color ?? _kindTint(block.kind));
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
        cursor: widget.dragging ? SystemMouseCursors.grabbing : SystemMouseCursors.grab,
        onEnter: (e) {
          if (isMouseHover(e)) setState(() => _hover = true);
        },
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => type.execute(context, block),
          onLongPress: () {
            Feedback.forLongPress(context);
            showBlockMenu(context, block, onBringToFront: widget.onBringToFront);
          },
          onSecondaryTapUp: (d) =>
              showBlockMenu(context, block, anchor: d.globalPosition, onBringToFront: widget.onBringToFront),
          child: SpecularGlassCard(
            key: ValueKey('card-${block.id}'),
            radius: 20,
            hover: _hover,
            elevated: widget.dragging,
            tintAccent: effectiveTint,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 13, 11, 11),
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
                          color: (stickyColor.color ?? c.fill).withValues(alpha: stickyColor.color != null ? 0.22 : 0.72),
                          borderRadius: BorderRadius.circular(AppRadius.s),
                        ),
                        child: emoji.isNotEmpty
                            ? Emoji(emoji, size: 15)
                            : Icon(type.icon, size: 13, color: stickyColor.color ?? c.text2),
                      ),
                      const SizedBox(width: Gap.s),
                      Expanded(
                        child: Text(
                          block.title.isEmpty ? '无标题' : block.title,
                          key: const Key('cardTitle'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: tt.titleSmall?.copyWith(
                            fontSize: 15.2,
                            fontWeight: FontWeight.w600,
                            letterSpacing: -0.2,
                            color: completed ? c.text2 : c.text,
                            decoration: completed ? TextDecoration.lineThrough : null,
                            decorationColor: c.text3,
                          ),
                        ),
                      ),
                      if (unread && !completed) ...[
                        const SizedBox(width: Gap.xs),
                        Container(
                          key: const Key('unreadDot'),
                          width: 7,
                          height: 7,
                          decoration: BoxDecoration(color: c.accent, shape: BoxShape.circle),
                        ),
                      ],
                      const SizedBox(width: 2),
                      // 便签优先级色点快捷入口
                      Builder(
                        builder: (dotCtx) => Tooltip(
                          message: stickyColor.tag.isEmpty ? '设置优先级与颜色' : '${stickyColor.label}（点击切换）',
                          child: InkWell(
                            key: ValueKey('stickyColorBtn-${block.id}'),
                            borderRadius: BorderRadius.circular(10),
                            onTap: () {
                              Offset? anchor;
                              final box = dotCtx.findRenderObject() as RenderBox?;
                              if (box != null) anchor = box.localToGlobal(Offset(box.size.width / 2, box.size.height));
                              showStickyColorPicker(context, block, anchor: anchor);
                            },
                            child: Padding(
                              padding: const EdgeInsets.all(4),
                              child: Container(
                                width: 11,
                                height: 11,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: stickyColor.color ?? c.text3.withValues(alpha: 0.24),
                                  border: Border.all(
                                    color: stickyColor.color != null
                                        ? Colors.white.withValues(alpha: 0.85)
                                        : c.text3.withValues(alpha: 0.45),
                                    width: 1.2,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      _CompleteCheckButton(block: block, size: 22),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Expanded(
                    child: Text(
                      bodyText,
                      key: const Key('cardPreview'),
                      maxLines: 5,
                      overflow: TextOverflow.ellipsis,
                      style: tt.bodySmall?.copyWith(color: c.text2, fontSize: 12.8, height: 1.5),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      if (completed) ...[
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                          decoration: BoxDecoration(
                            color: c.success.withValues(alpha: 0.18),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: c.success.withValues(alpha: 0.42), width: 0.8),
                          ),
                          child: Text(
                            '已完成',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                              color: c.success,
                              height: 1.2,
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                      ] else if (stickyColor.tag.isNotEmpty && stickyColor.color != null) ...[
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                          decoration: BoxDecoration(
                            color: stickyColor.color!.withValues(alpha: 0.18),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: stickyColor.color!.withValues(alpha: 0.42), width: 0.8),
                          ),
                          child: Text(
                            stickyColor.tag,
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                              color: stickyColor.color,
                              height: 1.2,
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                      ],
                      Expanded(
                        child: Text(
                          block.pending ? '待同步 · ${relTime(block.updatedAt)}' : relTime(block.updatedAt),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: tt.bodySmall?.copyWith(color: c.text3, fontSize: 11),
                        ),
                      ),
                      if (!(isDesktop && _hover && !widget.dragging)) ...[
                        Icon(
                          block.pending ? CupertinoIcons.cloud_upload : CupertinoIcons.cloud,
                          size: 14,
                          color: block.pending ? c.warning : c.text3.withValues(alpha: 0.85),
                        ),
                        const SizedBox(width: 2),
                      ],
                      if (isDesktop && _hover && !widget.dragging) ...[
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
                          dimension: 26,
                          child: IconButton(
                            key: const Key('cardMore'),
                            style: IconButton.styleFrom(
                              fixedSize: const Size.square(26),
                              minimumSize: const Size.square(26),
                              padding: EdgeInsets.zero,
                            ),
                            iconSize: 15,
                            icon: Icon(CupertinoIcons.ellipsis, color: c.text2),
                            tooltip: '更多',
                            onPressed: () {
                              Offset? anchor;
                              if (isDesktop && Glass.useShader) {
                                final box = btnCtx.findRenderObject() as RenderBox?;
                                if (box != null) anchor = box.localToGlobal(Offset(box.size.width, box.size.height + 4));
                              }
                              showBlockMenu(context, block, anchor: anchor, onBringToFront: widget.onBringToFront);
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
/// - 保留便签重要级别色条标识，与便签画布双向同步
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
    final completed = isBlockCompleted(block);
    final stickyColor = stickyColorOf(block);
    final emoji = block.kind == BlockKind.page
        ? (block.payload['icon'] ?? '') as String
        : block.kind == BlockKind.folder
            ? (block.payload['icon'] ?? 'folder') as String
            : '';
    var preview = type.previewText(context, block);
    if (preview.isEmpty) preview = type.label;

    final dark = Theme.of(context).brightness == Brightness.dark;
    final translucent = Glass.surfaceTranslucent;
    final accentTint = completed ? c.success : stickyColor.color;
    final baseGlass = accentTint != null && translucent
        ? Color.lerp(c.elevated, accentTint, dark ? 0.22 : 0.12)!
        : c.elevated;
    final cardBg = _hover
        ? (translucent ? baseGlass.withValues(alpha: dark ? 0.56 : 0.78) : c.hover)
        : (translucent ? baseGlass.withValues(alpha: dark ? 0.30 : 0.48) : Colors.transparent);

    final rowWidget = Semantics(
      button: true,
      label: '${block.title}，$preview${completed ? '，已完成' : (unread ? '，未读' : '')}',
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
            padding: const EdgeInsets.only(left: Gap.s, right: Gap.xs),
            decoration: BoxDecoration(
              color: cardBg,
              borderRadius: BorderRadius.circular(translucent ? AppRadius.l : AppRadius.m),
              border: translucent
                  ? Border.all(
                      color: accentTint != null
                          ? accentTint.withValues(alpha: _hover ? 0.55 : 0.34)
                          : (_hover
                              ? (dark ? Colors.white.withValues(alpha: 0.28) : Colors.white.withValues(alpha: 0.92))
                              : (dark ? Colors.white.withValues(alpha: 0.14) : Colors.white.withValues(alpha: 0.68))),
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
              if (accentTint != null) ...[
                Container(
                  width: 3.5,
                  height: 26,
                  decoration: BoxDecoration(
                    color: accentTint,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(width: Gap.xs),
              ],
              _CompleteCheckButton(block: block, size: 26),
              const SizedBox(width: Gap.xs),
              Container(
                width: Sizes.tile,
                height: Sizes.tile,
                alignment: Alignment.center,
                decoration: BoxDecoration(color: c.fill, borderRadius: BorderRadius.circular(AppRadius.s)),
                child: emoji.isNotEmpty ? Emoji(emoji, size: Sizes.iconMd) : Icon(type.icon, size: Sizes.iconSm, color: c.text2),
              ),
              const SizedBox(width: Gap.m),
              Expanded(
                child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
                    Expanded(
                      child: Text(
                        block.title.isEmpty ? '无标题' : block.title,
                        key: const Key('cardTitle'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: tt.labelLarge?.copyWith(
                          color: completed ? c.text2 : null,
                          decoration: completed ? TextDecoration.lineThrough : null,
                          decorationColor: c.text3,
                        ),
                      ),
                    ),
                    if (!completed && stickyColor.tag.isNotEmpty && stickyColor.color != null) ...[
                      const SizedBox(width: Gap.xs),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                        decoration: BoxDecoration(
                          color: stickyColor.color!.withValues(alpha: 0.16),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          stickyColor.tag,
                          style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w600, color: stickyColor.color),
                        ),
                      ),
                    ],
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
                      child: unread && !completed
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
          fixedSize: const Size.square(26),
          minimumSize: const Size.square(26),
          padding: EdgeInsets.zero,
        ),
        iconSize: 14.5,
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
Future<void> showBlockMenu(
  BuildContext context,
  Block block, {
  Offset? anchor,
  VoidCallback? onBringToFront,
}) async {
  final s = AppScope.of(context);
  final type = BlockTypes.of(block.kind);
  final extra = type.extraActions(context, block);
  final banned = s.sync.descendantIds(block.id)..add(block.id);
  final folders = s.sync.blocks
      .where((b) => b.kind == BlockKind.folder && !b.deleted && !banned.contains(b.id) && b.id != block.parentId)
      .toList();
  final messenger = ScaffoldMessenger.maybeOf(context);
  final title = block.title.isEmpty ? '无标题' : block.title;
  final currentColor = stickyColorOf(block);
  final completed = isBlockCompleted(block);

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
        ContextMenuItem(
          key: const Key('menuComplete'),
          icon: completed ? CupertinoIcons.circle : CupertinoIcons.checkmark_circle_fill,
          label: completed ? '取消完成' : '标为已完成',
          onTap: () => setBlockCompleted(s.sync, block, !completed),
        ),
        for (final a in extra) ContextMenuItem(icon: a.icon, label: a.label, onTap: a.run),
        const ContextMenuDivider(),
        ContextMenuItem(
          icon: CupertinoIcons.paintbrush,
          label: currentColor.tag.isEmpty ? '优先级与颜色…' : '优先级：${currentColor.tag}…',
          onTap: () => showStickyColorPicker(context, block, anchor: anchor),
        ),
        if (onBringToFront != null)
          ContextMenuItem(
            icon: CupertinoIcons.square_stack_3d_up,
            label: '置顶到最前',
            onTap: onBringToFront,
          ),
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
            padding: const EdgeInsets.fromLTRB(Gap.l, 0, Gap.l, Gap.s),
            child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: tt.titleMedium),
          ),
          // 便签重要级别颜色快捷条
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.l, 0, Gap.l, Gap.m),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final opt in stickyColorOptions)
                  _ColorSwatchChip(
                    option: opt,
                    selected: opt.key == currentColor.key,
                    onTap: () {
                      setStickyColor(s.sync, block, opt.key);
                      Navigator.pop(c);
                    },
                  ),
              ],
            ),
          ),
          MenuRow(icon: type.icon, label: type.executeLabel, onTap: () {
            Navigator.pop(c);
            type.execute(context, block);
          }),
          MenuRow(icon: CupertinoIcons.pencil, label: '编辑', onTap: () {
            Navigator.pop(c);
            type.edit(context, block);
          }),
          MenuRow(
            key: const Key('menuComplete'),
            icon: completed ? CupertinoIcons.circle : CupertinoIcons.checkmark_circle_fill,
            label: completed ? '取消完成' : '标为已完成',
            onTap: () {
              Navigator.pop(c);
              setBlockCompleted(s.sync, block, !completed);
            },
          ),
          if (onBringToFront != null)
            MenuRow(icon: CupertinoIcons.square_stack_3d_up, label: '置顶到最前', onTap: () {
              Navigator.pop(c);
              onBringToFront();
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

/// 自由拖拽、可堆叠、可按优先级分色排列的液态玻璃便签画布；
/// 未完成便签始终位于顶部主画布，已完成便签单独收纳在底部“已完成”区。
class _StickyBoardCanvas extends StatefulWidget {
  final List<Block> activeItems;
  final List<Block> completedItems;
  final bool showCompleted;
  final VoidCallback onToggleCompleted;
  final String? enterId;
  final double topPadding;
  final double bottomPadding;
  const _StickyBoardCanvas({
    super.key,
    required this.activeItems,
    required this.completedItems,
    required this.showCompleted,
    required this.onToggleCompleted,
    required this.enterId,
    required this.topPadding,
    required this.bottomPadding,
  });

  @override
  State<_StickyBoardCanvas> createState() => _StickyBoardCanvasState();
}

class _StickyBoardCanvasState extends State<_StickyBoardCanvas> {
  static const double _cardW = 256.0;
  static const double _cardH = 208.0;
  static const double _gapX = 18.0;
  static const double _gapY = 18.0;

  final Map<String, Offset> _livePos = {};
  final Map<String, double> _liveZ = {};
  String? _draggingId;

  Offset _defaultPos(int index, double boardWidth) {
    final usableW = math.max(_cardW, boardWidth - 40.0);
    final cols = math.max(1, math.min(5, ((usableW + _gapX) / (_cardW + _gapX)).floor()));
    final totalRowW = cols * _cardW + (cols - 1) * _gapX;
    final startX = math.max(20.0, (boardWidth - totalRowW) / 2);
    final col = index % cols;
    final row = index ~/ cols;
    final staggerY = col.isOdd ? 12.0 : 0.0;
    return Offset(
      startX + col * (_cardW + _gapX),
      widget.topPadding + 36.0 + row * (_cardH + _gapY) + staggerY,
    );
  }

  Offset _posOf(Block b, int index, double boardWidth) {
    final live = _livePos[b.id];
    if (live != null) return live;
    final sx = _numField(b.payload, 'sticky_x');
    final sy = _numField(b.payload, 'sticky_y');
    if (sx != null && sy != null) {
      final maxX = math.max(16.0, boardWidth - _cardW - 16.0);
      return Offset(sx.clamp(16.0, maxX), math.max(widget.topPadding + 10.0, sy));
    }
    return _defaultPos(index, boardWidth);
  }

  double _zOf(Block b, int index) {
    return _liveZ[b.id] ?? _numField(b.payload, 'sticky_z') ?? index.toDouble();
  }

  double _maxZ(List<Block> items) {
    double m = 0;
    for (var i = 0; i < items.length; i++) {
      m = math.max(m, _zOf(items[i], i));
    }
    return m;
  }

  void _bringToFront(SyncClient sync, Block b, List<Block> items, {bool persist = true}) {
    final nextZ = _maxZ(items) + 1.0;
    setState(() => _liveZ[b.id] = nextZ);
    if (persist) {
      sync.update(b.id, payload: {...b.payload, 'sticky_z': nextZ.round()});
    }
  }

  void _tidyAll(SyncClient sync, List<Block> items, double boardWidth) {
    for (var i = 0; i < items.length; i++) {
      final b = items[i];
      final p = _defaultPos(i, boardWidth);
      sync.update(
        b.id,
        payload: {
          ...b.payload,
          'sticky_x': p.dx.round(),
          'sticky_y': p.dy.round(),
          'sticky_z': i + 1,
        },
      );
    }
    setState(() {
      _livePos.clear();
      _liveZ.clear();
    });
  }

  Widget _wrapEnter(Block b, Widget card) {
    if (b.id != widget.enterId) return card;
    return _FadeIn(key: ValueKey('enter-${b.id}'), child: card);
  }

  @override
  Widget build(BuildContext context) {
    final sync = AppScope.of(context).sync;
    final c = AppColors.of(context);
    final active = widget.activeItems;
    final completed = widget.completedItems;

    return LayoutBuilder(
      builder: (context, constraints) {
        final boardW = constraints.maxWidth;

        // 窄屏手机：未完成便签网格置顶，已完成便签单独收纳在底部区域
        if (boardW < 520) {
          final gridDelegate = SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: boardW >= 360 ? 2 : 1,
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            childAspectRatio: boardW >= 360 ? 0.94 : 1.55,
          );
          return CustomScrollView(
            key: const Key('blockGridView'),
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              if (active.isNotEmpty)
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(
                    Gap.l,
                    widget.topPadding,
                    Gap.l,
                    completed.isEmpty ? widget.bottomPadding : Gap.m,
                  ),
                  sliver: SliverGrid(
                    gridDelegate: gridDelegate,
                    delegate: SliverChildBuilderDelegate(
                      (context, i) => _wrapEnter(active[i], StickyNoteCard(block: active[i])),
                      childCount: active.length,
                    ),
                  ),
                ),
              if (completed.isNotEmpty) ...[
                SliverToBoxAdapter(
                  child: _CompletedSectionHeader(
                    count: completed.length,
                    expanded: widget.showCompleted,
                    onToggle: widget.onToggleCompleted,
                    padding: EdgeInsets.fromLTRB(
                      Gap.l,
                      active.isEmpty ? widget.topPadding : Gap.s,
                      Gap.l,
                      Gap.s,
                    ),
                  ),
                ),
                if (widget.showCompleted)
                  SliverPadding(
                    padding: EdgeInsets.fromLTRB(Gap.l, 0, Gap.l, widget.bottomPadding),
                    sliver: SliverGrid(
                      gridDelegate: gridDelegate,
                      delegate: SliverChildBuilderDelegate(
                        (context, i) => Opacity(
                          opacity: 0.82,
                          child: _wrapEnter(completed[i], StickyNoteCard(block: completed[i])),
                        ),
                        childCount: completed.length,
                      ),
                    ),
                  )
                else
                  SliverToBoxAdapter(child: SizedBox(height: widget.bottomPadding)),
              ],
            ],
          );
        }

        // 桌面 / 平板：顶部自由拖拽未完成画布 + 底部独立“已完成”区
        final indexed = <(Block, int, Offset, double)>[];
        double activeBottom = active.isEmpty ? widget.topPadding + 16.0 : widget.topPadding + _cardH + 64.0;
        for (var i = 0; i < active.length; i++) {
          final b = active[i];
          final pos = _posOf(b, i, boardW);
          final z = _zOf(b, i);
          indexed.add((b, i, pos, z));
          activeBottom = math.max(activeBottom, pos.dy + _cardH + 28.0);
        }
        indexed.sort((a, b) => a.$4.compareTo(b.$4));

        final canvasHeight = completed.isEmpty
            ? math.max(constraints.maxHeight, activeBottom + widget.bottomPadding)
            : activeBottom;

        return Stack(
          children: [
            SingleChildScrollView(
              key: const Key('blockGridView'),
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              physics: const AlwaysScrollableScrollPhysics(),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (active.isNotEmpty)
                    SizedBox(
                      width: boardW,
                      height: canvasHeight,
                      child: Stack(
                        clipBehavior: Clip.none,
                        children: [
                          for (final entry in indexed)
                            Builder(
                              builder: (context) {
                                final b = entry.$1;
                                final pos = entry.$3;
                                final isDragging = _draggingId == b.id;
                                Widget card = StickyNoteCard(
                                  block: b,
                                  dragging: isDragging,
                                  onBringToFront: () => _bringToFront(sync, b, active),
                                );
                                card = _wrapEnter(b, card);
                                return Positioned(
                                  key: ValueKey('sticky-pos-${b.id}'),
                                  left: pos.dx,
                                  top: pos.dy,
                                  width: _cardW,
                                  height: _cardH,
                                  child: GestureDetector(
                                    onPanStart: (_) {
                                      final nextZ = _maxZ(active) + 1.0;
                                      setState(() {
                                        _draggingId = b.id;
                                        _livePos[b.id] = pos;
                                        _liveZ[b.id] = nextZ;
                                      });
                                    },
                                    onPanUpdate: (d) {
                                      final cur = _livePos[b.id] ?? pos;
                                      final maxX = math.max(16.0, boardW - _cardW - 16.0);
                                      final nx = (cur.dx + d.delta.dx).clamp(16.0, maxX);
                                      final ny = math.max(widget.topPadding + 8.0, cur.dy + d.delta.dy);
                                      setState(() => _livePos[b.id] = Offset(nx, ny));
                                    },
                                    onPanEnd: (_) {
                                      final finalPos = _livePos[b.id] ?? pos;
                                      final finalZ = _liveZ[b.id] ?? entry.$4;
                                      setState(() => _draggingId = null);
                                      sync.update(
                                        b.id,
                                        payload: {
                                          ...b.payload,
                                          'sticky_x': finalPos.dx.round(),
                                          'sticky_y': finalPos.dy.round(),
                                          'sticky_z': finalZ.round(),
                                        },
                                      );
                                    },
                                    onPanCancel: () => setState(() => _draggingId = null),
                                    child: AnimatedScale(
                                      scale: isDragging ? 1.035 : 1.0,
                                      duration: Motion.short2,
                                      curve: Curves.easeOutCubic,
                                      child: card,
                                    ),
                                  ),
                                );
                              },
                            ),
                        ],
                      ),
                    ),
                  if (completed.isNotEmpty) ...[
                    _CompletedSectionHeader(
                      count: completed.length,
                      expanded: widget.showCompleted,
                      onToggle: widget.onToggleCompleted,
                      padding: EdgeInsets.fromLTRB(
                        24,
                        active.isEmpty ? widget.topPadding + 12 : Gap.m,
                        24,
                        Gap.m,
                      ),
                    ),
                    if (widget.showCompleted)
                      Padding(
                        padding: EdgeInsets.fromLTRB(24, 0, 24, widget.bottomPadding + 20),
                        child: Wrap(
                          spacing: _gapX,
                          runSpacing: _gapY,
                          children: [
                            for (final b in completed)
                              SizedBox(
                                width: _cardW,
                                height: _cardH,
                                child: Opacity(
                                  opacity: 0.82,
                                  child: _wrapEnter(b, StickyNoteCard(block: b)),
                                ),
                              ),
                          ],
                        ),
                      )
                    else
                      SizedBox(height: widget.bottomPadding + 20),
                  ],
                ],
              ),
            ),
            if (active.isNotEmpty)
              // 右上角轻量化「整理排列」悬浮玻璃胶囊（按优先级与创建时间排列）
              Positioned(
                top: widget.topPadding + 2,
                right: 20,
                child: Tooltip(
                  message: '按优先级与创建时间整齐排列便签',
                  child: Glass(
                    radius: 14,
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    child: Material(
                      type: MaterialType.transparency,
                      child: InkWell(
                        key: const Key('tidyStickyButton'),
                        borderRadius: BorderRadius.circular(12),
                        onTap: () => _tidyAll(sync, active, boardW),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(CupertinoIcons.square_grid_2x2, size: 13, color: c.text2),
                            const SizedBox(width: 5),
                            Text(
                              '整理排列',
                              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                    fontSize: 11.5,
                                    fontWeight: FontWeight.w500,
                                    color: c.text2,
                                  ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// 动画块列表（支持便签画布与普通列表视图；按完成状态 → 优先级 → 创建时间排序）。
class BlockList extends StatefulWidget {
  final String? parentId;
  final String filter;

  /// 只显示这些类型（null = 全部）
  final Set<BlockKind>? kinds;

  /// true = 自由拖拽堆叠液态玻璃便签画布；false = 普通单列列表
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

  @override
  State<BlockList> createState() => _BlockListState();
}

class _BlockListState extends State<BlockList> {
  static final Set<String> _known = {};
  static var _ready = false;

  bool _showCompleted = true;

  @override
  Widget build(BuildContext context) {
    final sync = AppScope.of(context).sync;
    return ListenableBuilder(
      listenable: sync,
      builder: (context, _) {
        var items = widget.filter.isEmpty
            ? sync.childrenOf(widget.parentId)
            : sync.blocks.where((b) {
                if (!SyncClient.isInboxItem(b)) return false;
                final q = widget.filter.toLowerCase();
                return b.title.toLowerCase().contains(q) ||
                    b.payload.values.whereType<String>().any((v) => v.toLowerCase().contains(q));
              }).toList();
        if (widget.kinds != null) items = items.where((b) => widget.kinds!.contains(b.kind)).toList();
        items.sort(compareInboxBlocks);

        final activeItems = [for (final b in items) if (!isBlockCompleted(b)) b];
        final completedItems = [for (final b in items) if (isBlockCompleted(b)) b];

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

        final kindKey = widget.kinds == null ? 'all' : widget.kinds!.map((k) => k.name).join('-');
        final Widget content;
        if (items.isEmpty) {
          content = LayoutBuilder(
            key: ValueKey('empty-$kindKey-${widget.gridMode}'),
            builder: (context, c) => SingleChildScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: EdgeInsets.only(top: widget.topPadding, bottom: widget.bottomPadding),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minHeight: (c.maxHeight - widget.topPadding - widget.bottomPadding).clamp(0.0, double.infinity),
                ),
                child: Center(
                  child: EmptyState(
                    key: const Key('emptyState'),
                    icon: widget.filter.isEmpty ? CupertinoIcons.tray : CupertinoIcons.search,
                    title: widget.filter.isEmpty ? '这里还没有内容' : '没有匹配的结果',
                    subtitle: widget.filter.isEmpty ? '在下方输入框发送消息，或点击右侧 + 新建笔记、页面、文件' : '换个关键词试试',
                  ),
                ),
              ),
            ),
          );
        } else if (widget.gridMode) {
          content = _StickyBoardCanvas(
            key: ValueKey('board-$kindKey'),
            activeItems: activeItems,
            completedItems: completedItems,
            showCompleted: _showCompleted,
            onToggleCompleted: () => setState(() => _showCompleted = !_showCompleted),
            enterId: enterId,
            topPadding: widget.topPadding,
            bottomPadding: widget.bottomPadding,
          );
        } else {
          Widget buildRow(Block b) {
            final card = BlockCard(block: b);
            if (b.id != enterId) return card;
            return _FadeIn(key: ValueKey('enter-${b.id}'), child: card);
          }

          final rows = <Widget>[
            for (final b in activeItems) buildRow(b),
            if (completedItems.isNotEmpty) ...[
              _CompletedSectionHeader(
                count: completedItems.length,
                expanded: _showCompleted,
                onToggle: () => setState(() => _showCompleted = !_showCompleted),
              ),
              if (_showCompleted)
                for (final b in completedItems) buildRow(b),
            ],
          ];

          content = ListView.builder(
            key: const Key('blockListView'),
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: EdgeInsets.only(top: widget.topPadding, bottom: widget.bottomPadding),
            itemCount: rows.length,
            itemBuilder: (context, i) => rows[i],
          );
        }

        // 在测试/无着色器模式下直出，避免额外 AnimatedSwitcher 干扰瞬时 widget 断言
        if (!Glass.useShader) return content;

        return MotionSwitch(
          duration: Motion.short4,
          child: KeyedSubtree(
            key: ValueKey('${items.isEmpty ? "empty" : (widget.gridMode ? "board" : "list")}-$kindKey'),
            child: content,
          ),
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
