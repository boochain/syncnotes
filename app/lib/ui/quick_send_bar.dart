import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../blocks/block_type.dart';
import '../models/block.dart';
import '../platform/desktop.dart';
import 'block_card.dart';
import 'ds.dart';
import 'glass.dart';

/// 底部常驻快速发送消息栏 + 右侧独立圆形新建按钮：
/// - 左侧常驻消息输入框与发送按钮，随时快速发送消息到列表；
/// - 右侧独立圆形「+」按钮，一键新建笔记 / 页面 / 文件 / 文件夹。
class QuickSendBar extends StatefulWidget {
  final String? parentId;

  /// 开启悬浮模式时渲染为独立圆角液态玻璃发送胶囊 + 右侧独立圆形玻璃加号按钮。
  final bool floating;

  const QuickSendBar({
    super.key,
    this.parentId,
    this.floating = false,
  });

  @override
  State<QuickSendBar> createState() => _QuickSendBarState();
}

class _QuickSendBarState extends State<QuickSendBar> {
  final _ctrl = TextEditingController();
  final _focus = FocusNode();

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

  void _openCreate(BuildContext btnCtx) {
    Offset? anchor;
    if (isDesktop && Glass.useShader) {
      final box = btnCtx.findRenderObject() as RenderBox?;
      if (box != null) anchor = box.localToGlobal(Offset(box.size.width / 2, -10));
    }
    showCreateMenu(context, parentId: widget.parentId, anchor: anchor);
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

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final empty = _ctrl.text.trim().isEmpty;
    final useFloatingGlass = widget.floating && Glass.surfaceTranslucent;
    final ctrlH = useFloatingGlass ? 36.0 : Sizes.input;
    final iconSz = useFloatingGlass ? 17.0 : Sizes.iconMd;

    final inputField = ConstrainedBox(
      constraints: BoxConstraints(minHeight: ctrlH),
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
            borderRadius: BorderRadius.circular(ctrlH / 2),
            borderSide: BorderSide(color: c.accent, width: 1.5),
          ),
          contentPadding: useFloatingGlass
              ? EdgeInsets.symmetric(horizontal: Gap.l, vertical: (ctrlH - 18) / 2)
              : const EdgeInsets.symmetric(horizontal: Gap.l + 2, vertical: (Sizes.input - 20) / 2),
        ),
      ),
    );

    final sendButton = SizedBox.square(
      dimension: ctrlH,
      child: IconButton(
        key: const Key('quickSendButton'),
        style: IconButton.styleFrom(
          fixedSize: Size.square(ctrlH),
          minimumSize: Size.square(ctrlH),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          padding: EdgeInsets.zero,
          shape: const CircleBorder(),
          backgroundColor: empty ? c.fill : c.accent,
          foregroundColor: empty ? c.text3 : Colors.white,
        ),
        icon: Icon(CupertinoIcons.arrow_up, size: iconSz),
        tooltip: '发送',
        onPressed: _send,
      ),
    );

    if (useFloatingGlass) {
      // 常驻悬浮消息发送胶囊 + 右侧独立圆形新建按钮（两者等高 46px）
      final sendPill = Glass(
        radius: 23,
        padding: const EdgeInsets.fromLTRB(6, 5, 5, 5),
        child: Material(
          type: MaterialType.transparency,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(child: inputField),
              const SizedBox(width: Gap.xs),
              sendButton,
            ],
          ),
        ),
      );

      final addCircle = Builder(
        builder: (btnCtx) => Glass(
          radius: 23,
          padding: const EdgeInsets.all(5),
          child: Material(
            type: MaterialType.transparency,
            child: SizedBox.square(
              dimension: ctrlH,
              child: IconButton(
                key: const Key('quickNewButton'),
                style: IconButton.styleFrom(
                  fixedSize: Size.square(ctrlH),
                  minimumSize: Size.square(ctrlH),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  padding: EdgeInsets.zero,
                  shape: const CircleBorder(),
                ),
                icon: Icon(CupertinoIcons.add, size: 19, color: c.text),
                tooltip: '新建',
                onPressed: () => _openCreate(btnCtx),
              ),
            ),
          ),
        ),
      );

      return SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Gap.l, Gap.xs, Gap.l, Gap.m + 2),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 620),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(child: sendPill),
                  const SizedBox(width: 10),
                  addCircle,
                ],
              ),
            ),
          ),
        ),
      );
    }

    // 常规底栏（关闭玻璃或测试模式下）：常驻发送框 + 发送按钮 + 右侧独立圆形加号按钮
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
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(child: inputField),
                  const SizedBox(width: Gap.xs),
                  sendButton,
                  const SizedBox(width: Gap.s),
                  Builder(
                    builder: (btnCtx) => SizedBox.square(
                      dimension: Sizes.input,
                      child: IconButton(
                        key: const Key('quickNewButton'),
                        style: IconButton.styleFrom(
                          fixedSize: const Size.square(Sizes.input),
                          minimumSize: const Size.square(Sizes.input),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          padding: EdgeInsets.zero,
                          shape: CircleBorder(side: BorderSide(color: c.separator)),
                          backgroundColor: c.elevated,
                          foregroundColor: c.text,
                        ),
                        icon: const Icon(CupertinoIcons.add, size: Sizes.iconMd),
                        tooltip: '新建',
                        onPressed: () => _openCreate(btnCtx),
                      ),
                    ),
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
