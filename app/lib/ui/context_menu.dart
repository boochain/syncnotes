import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'ds.dart';
import 'motion.dart';

/// 桌面端右键上下文菜单项。
sealed class ContextMenuEntry {
  const ContextMenuEntry();
}

class ContextMenuItem extends ContextMenuEntry {
  final Key? key;
  final IconData icon;
  final String label;
  final String? shortcut;
  final bool danger;
  final bool checked;
  final VoidCallback onTap;

  const ContextMenuItem({
    this.key,
    required this.icon,
    required this.label,
    this.shortcut,
    this.danger = false,
    this.checked = false,
    required this.onTap,
  });
}

class ContextMenuDivider extends ContextMenuEntry {
  const ContextMenuDivider();
}

/// 在鼠标点击位置（[anchor]）弹出 Apple Liquid Glass 风格上下文菜单。
/// 自动限制在屏幕视口内，支持键盘 Esc 关闭、鼠标悬停高亮与快捷键提示。
Future<void> showGlassContextMenu(
  BuildContext context, {
  required Offset anchor,
  required List<ContextMenuEntry> items,
  String? header,
}) async {
  await showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: '关闭上下文菜单',
    barrierColor: Colors.transparent,
    transitionDuration: const Duration(milliseconds: 140),
    pageBuilder: (ctx, a1, a2) => _GlassContextMenuOverlay(
      animation: a1,
      anchor: anchor,
      items: items,
      header: header,
    ),
    transitionBuilder: (ctx, animation, secondaryAnimation, child) {
      final curved = CurvedAnimation(parent: animation, curve: Curves.easeOutCubic, reverseCurve: Curves.easeInCubic);
      // 缩放在菜单自身上做、原点跟随锚点（见 _GlassContextMenuOverlay）；这里只淡入淡出。
      return FadeTransition(opacity: curved, child: child);
    },
  );
}

class _GlassContextMenuOverlay extends StatelessWidget {
  final Animation<double> animation;
  final Offset anchor;
  final List<ContextMenuEntry> items;
  final String? header;

  const _GlassContextMenuOverlay({
    required this.animation,
    required this.anchor,
    required this.items,
    this.header,
  });

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    const menuWidth = 228.0;
    const pad = 10.0;

    // 估算高度用于自动防裁切定位
    double estHeight = 14.0;
    if (header != null && header!.isNotEmpty) estHeight += 28.0;
    for (final it in items) {
      estHeight += it is ContextMenuDivider ? 9.0 : 32.0;
    }

    double left = anchor.dx;
    double top = anchor.dy;
    final flipX = left + menuWidth + pad > size.width;
    final flipY = top + estHeight + pad > size.height;
    // M3 / HIG：菜单从触发点展开——向左 / 向上翻转时原点也跟着换到右 / 下角
    final origin = Alignment(flipX ? 1 : -1, flipY ? 1 : -1);
    if (flipX) {
      left = (anchor.dx - menuWidth).clamp(pad, (size.width - menuWidth - pad).clamp(pad, double.infinity));
    } else {
      left = left.clamp(pad, (size.width - menuWidth - pad).clamp(pad, double.infinity));
    }
    if (flipY) {
      top = (anchor.dy - estHeight).clamp(pad, (size.height - estHeight - pad).clamp(pad, double.infinity));
    } else {
      top = top.clamp(pad, (size.height - estHeight - pad).clamp(pad, double.infinity));
    }

    final c = AppColors.of(context);
    final tt = Theme.of(context).textTheme;

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () => Navigator.of(context).pop(),
      },
      child: Focus(
        autofocus: true,
        child: Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: () => Navigator.of(context).pop(),
                onSecondaryTap: () => Navigator.of(context).pop(),
              ),
            ),
            Positioned(
              left: left,
              top: top,
              width: menuWidth,
              child: ScaleTransition(
                scale: Tween<double>(begin: 0.92, end: 1.0).animate(
                    CurvedAnimation(parent: animation, curve: Curves.easeOutCubic, reverseCurve: Curves.easeInCubic)),
                alignment: origin,
                // v0.8.2：不透明卡片（下层页面由 PopupCover 盖住，只露背景）
                child: CardSurface(
                radius: AppRadius.l,
                child: Padding(
                padding: const EdgeInsets.all(5),
                child: Material(
                  type: MaterialType.transparency,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxHeight: (size.height - 2 * pad).clamp(120.0, 520.0)),
                    child: SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (header != null && header!.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.fromLTRB(10, 4, 10, 6),
                              child: Text(
                                header!,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: tt.bodySmall?.copyWith(color: c.text3, fontWeight: FontWeight.w600),
                              ),
                            ),
                          for (final entry in items)
                            switch (entry) {
                              ContextMenuDivider() => Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                  child: Divider(height: 1, thickness: 1, color: c.separator.withValues(alpha: 0.7)),
                                ),
                              ContextMenuItem() => _ContextMenuRow(
                                  item: entry,
                                  onTriggered: () {
                                    Navigator.of(context).pop();
                                    entry.onTap();
                                  },
                                ),
                            },
                        ],
                      ),
                    ),
                  ),
                ),
                ),
              ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ContextMenuRow extends StatefulWidget {
  final ContextMenuItem item;
  final VoidCallback onTriggered;

  const _ContextMenuRow({required this.item, required this.onTriggered});

  @override
  State<_ContextMenuRow> createState() => _ContextMenuRowState();
}

class _ContextMenuRowState extends State<_ContextMenuRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final tt = Theme.of(context).textTheme;
    final it = widget.item;
    final activeBg = it.danger ? c.danger : c.accent;
    final fg = _hover ? Colors.white : (it.danger ? c.danger : c.text);
    final iconFg = _hover ? Colors.white : (it.danger ? c.danger : c.text2);
    final hintFg = _hover ? Colors.white.withValues(alpha: 0.85) : c.text3;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (e) {
        if (isMouseHover(e)) setState(() => _hover = true);
      },
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        key: it.key,
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTriggered,
        child: Container(
          height: 30,
          padding: const EdgeInsets.symmetric(horizontal: 9),
          decoration: BoxDecoration(
            color: _hover ? activeBg : Colors.transparent,
            borderRadius: BorderRadius.circular(AppRadius.s),
          ),
          child: Row(
            children: [
              SizedBox(
                width: 18,
                child: Icon(it.icon, size: 14, color: iconFg),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  it.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: tt.bodyMedium?.copyWith(color: fg, fontSize: 13, height: 1.2),
                ),
              ),
              if (it.checked) ...[
                const SizedBox(width: 6),
                Icon(CupertinoIcons.checkmark, size: 13, color: _hover ? Colors.white : c.accent),
              ] else if (it.shortcut != null) ...[
                const SizedBox(width: 8),
                Text(
                  it.shortcut!,
                  style: tt.bodySmall?.copyWith(color: hintFg, fontSize: 11),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
