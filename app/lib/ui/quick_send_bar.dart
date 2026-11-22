import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_scope.dart';
import '../blocks/block_type.dart';
import '../models/block.dart';
import '../platform/desktop.dart';
import 'block_card.dart';
import 'ds.dart';
import 'glass.dart';
import 'motion.dart';
import 'tokens.dart';

/// 底部快速发送消息栏 / 概念图同款居中悬浮 4 图标液态玻璃底栏坞（支持桌面端与手机端）。
/// - 开启悬浮液态玻璃时默认呈现紧凑 4 图标悬浮胶囊（新建笔记 / 新建与上传 / 搜索 / 快速发送），
///   点击「快速发送」即帧模糊平滑展开为消息输入胶囊，Esc 或关闭按钮即可收起。
class QuickSendBar extends StatefulWidget {
  final String? parentId;

  /// 开启悬浮模式时渲染为独立圆角液态玻璃胶囊（内容列表/便利贴可从其下方滚过产生真实折射）。
  final bool floating;

  /// 点击悬浮底栏搜索图标时的回调（未传时自动展开快速发送输入框）。
  final VoidCallback? onSearch;

  const QuickSendBar({
    super.key,
    this.parentId,
    this.floating = false,
    this.onSearch,
  });
  @override
  State<QuickSendBar> createState() => _QuickSendBarState();
}

class _QuickSendBarState extends State<QuickSendBar> {
  final _ctrl = TextEditingController();
  final _focus = FocusNode();
  bool _composing = false;

  void _send() {
    final text = _ctrl.text.trim();
    if (text.isEmpty) return;
    AppScope.of(context).sync.create(
          kind: BlockKind.message,
          title: shortTitle(text),
          payload: {'text': text},
          parentId: widget.parentId,
          viewedMode: defaultViewedMode(context),
        );
    _ctrl.clear();
    _focus.requestFocus();
  }

  void _openCompose() {
    setState(() => _composing = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  void _closeCompose() {
    _focus.unfocus();
    setState(() => _composing = false);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _ctrl.addListener(() => setState(() {}));
  }

  Widget _dockIcon(
    BuildContext context, {
    Key? key,
    required IconData icon,
    required String tooltip,
    required VoidCallback onPressed,
  }) {
    final c = AppColors.of(context);
    return Tooltip(
      message: tooltip,
      child: SizedBox.square(
        dimension: 38,
        child: IconButton(
          key: key,
          style: IconButton.styleFrom(
            fixedSize: const Size.square(38),
            minimumSize: const Size.square(38),
            padding: EdgeInsets.zero,
            shape: const CircleBorder(),
          ),
          icon: Icon(icon, size: 18.5, color: c.text2),
          onPressed: onPressed,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final empty = _ctrl.text.trim().isEmpty;
    final useFloatingGlass = widget.floating && Glass.surfaceTranslucent;
    final ctrlH = useFloatingGlass ? 36.0 : Sizes.input;
    final iconSz = useFloatingGlass ? 17.0 : Sizes.iconMd;

    final composeRow = Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
      Builder(
        builder: (btnCtx) => SizedBox.square(
          dimension: ctrlH,
          child: IconButton(
            key: const Key('quickNewButton'),
            style: IconButton.styleFrom(
              fixedSize: Size.square(ctrlH),
              minimumSize: Size.square(ctrlH),
              padding: EdgeInsets.zero,
              shape: const CircleBorder(),
            ),
            icon: Icon(CupertinoIcons.add, size: iconSz),
            tooltip: '新建',
            onPressed: () {
              Offset? anchor;
              if (isDesktop && Glass.useShader) {
                final box = btnCtx.findRenderObject() as RenderBox?;
                if (box != null) anchor = box.localToGlobal(const Offset(0, -10));
              }
              showCreateMenu(context, parentId: widget.parentId, anchor: anchor);
            },
          ),
        ),
      ),
      const SizedBox(width: Gap.xs),
      Expanded(
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: ctrlH),
          child: CallbackShortcuts(
            bindings: {
              if (useFloatingGlass) const SingleActivator(LogicalKeyboardKey.escape): _closeCompose,
            },
            child: TextField(
              key: const Key('quickSendField'),
              controller: _ctrl,
              focusNode: _focus,
              minLines: 1,
              maxLines: 4,
              style: useFloatingGlass
                  ? Theme.of(context).textTheme.bodyMedium?.copyWith(fontSize: 13.5)
                  : Theme.of(context).textTheme.bodyMedium,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => _send(),
              decoration: InputDecoration(
                hintText: '快速发送消息…',
                filled: true,
                fillColor: useFloatingGlass ? c.fill.withValues(alpha: 0.36) : null,
                constraints: BoxConstraints(minHeight: ctrlH),
                isDense: true,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(ctrlH / 2), borderSide: BorderSide.none),
                enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(ctrlH / 2), borderSide: BorderSide.none),
                focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(ctrlH / 2), borderSide: BorderSide(color: c.accent, width: 1.5)),
                contentPadding: useFloatingGlass
                    ? EdgeInsets.symmetric(horizontal: Gap.l, vertical: (ctrlH - 18) / 2)
                    : const EdgeInsets.symmetric(horizontal: Gap.l + 2, vertical: (Sizes.input - 20) / 2),
              ),
            ),
          ),
        ),
      ),
      const SizedBox(width: Gap.xs),
      SizedBox.square(
        dimension: ctrlH,
        child: IconButton(
          key: const Key('quickSendButton'),
          style: IconButton.styleFrom(
            fixedSize: Size.square(ctrlH),
            minimumSize: Size.square(ctrlH),
            padding: EdgeInsets.zero,
            shape: const CircleBorder(),
            backgroundColor: empty ? c.fill : c.accent,
            foregroundColor: empty ? c.text3 : Colors.white,
          ),
          icon: Icon(CupertinoIcons.arrow_up, size: iconSz),
          tooltip: '发送',
          onPressed: _send,
        ),
      ),
      if (useFloatingGlass) ...[
        const SizedBox(width: 2),
        SizedBox.square(
          dimension: ctrlH,
          child: IconButton(
            style: IconButton.styleFrom(
              fixedSize: Size.square(ctrlH),
              minimumSize: Size.square(ctrlH),
              padding: EdgeInsets.zero,
              shape: const CircleBorder(),
            ),
            icon: Icon(CupertinoIcons.xmark, size: 15, color: c.text3),
            tooltip: '收起为图标底栏 (Esc)',
            onPressed: _closeCompose,
          ),
        ),
      ],
    ]);

    if (useFloatingGlass) {
      // 概念图同款紧凑 4 图标悬浮底栏胶囊 ↔ 展开快速发送胶囊（帧模糊平滑切换）
      final compactDock = Glass(
        key: const ValueKey('floatingDockCompact'),
        radius: 25,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
        child: Material(
          type: MaterialType.transparency,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _dockIcon(
                context,
                icon: CupertinoIcons.doc_text,
                tooltip: '新建 Markdown 笔记',
                onPressed: () => BlockTypes.of(BlockKind.note).edit(context, null, parentId: widget.parentId),
              ),
              const SizedBox(width: 10),
              Builder(
                builder: (btnCtx) => _dockIcon(
                  context,
                  key: const Key('quickNewButton'),
                  icon: CupertinoIcons.doc_on_doc,
                  tooltip: '新建 / 上传文件',
                  onPressed: () {
                    Offset? anchor;
                    if (isDesktop && Glass.useShader) {
                      final box = btnCtx.findRenderObject() as RenderBox?;
                      if (box != null) anchor = box.localToGlobal(const Offset(0, -10));
                    }
                    showCreateMenu(context, parentId: widget.parentId, anchor: anchor);
                  },
                ),
              ),
              const SizedBox(width: 10),
              _dockIcon(
                context,
                icon: CupertinoIcons.search,
                tooltip: '搜索',
                onPressed: widget.onSearch ?? _openCompose,
              ),
              const SizedBox(width: 10),
              _dockIcon(
                context,
                key: const Key('quickComposeToggle'),
                icon: CupertinoIcons.arrowshape_turn_up_right,
                tooltip: '快速发送消息',
                onPressed: _openCompose,
              ),
            ],
          ),
        ),
      );

      final expandedCompose = ConstrainedBox(
        key: const ValueKey('floatingDockCompose'),
        constraints: const BoxConstraints(maxWidth: 560),
        child: Glass(
          radius: 25,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Material(type: MaterialType.transparency, child: composeRow),
        ),
      );

      return SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Gap.l, Gap.xs, Gap.l, Gap.m + 2),
          child: Center(
            child: MotionSwitch(
              duration: Motion.short4,
              maxBlur: 6.0,
              child: _composing ? expandedCompose : compactDock,
            ),
          ),
        ),
      );
    }

    // 常规底栏（非悬浮或关闭玻璃/测试模式下）
    return Frosted(
      color: c.bg,
      child: Material(
        type: MaterialType.transparency,
        child: Container(
          decoration: BoxDecoration(border: Border(top: BorderSide(color: c.separator))),
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: Gap.m, vertical: Gap.m),
              child: composeRow,
            ),
          ),
        ),
      ),
    );
  }
}
