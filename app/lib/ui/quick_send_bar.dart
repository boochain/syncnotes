import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../blocks/block_type.dart';
import '../models/block.dart';
import '../platform/desktop.dart';
import 'block_card.dart';
import 'ds.dart';
import 'glass.dart';

/// 底部快速发送消息栏（Apple 信息 App 胶囊风格 + 居中悬浮 Liquid Glass 玻璃舱）。
class QuickSendBar extends StatefulWidget {
  final String? parentId;

  /// 开启悬浮模式时渲染为独立圆角液态玻璃胶囊（内容列表/便利贴可从其下方滚过产生真实折射）。
  final bool floating;
  const QuickSendBar({super.key, this.parentId, this.floating = false});
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

    final row = Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
      Builder(
        builder: (btnCtx) => SizedBox.square(
          dimension: Sizes.input,
          child: IconButton(
            key: const Key('quickNewButton'),
            style: IconButton.styleFrom(fixedSize: const Size.square(Sizes.input), shape: const CircleBorder()),
            icon: const Icon(CupertinoIcons.add, size: Sizes.iconMd),
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
          constraints: const BoxConstraints(minHeight: Sizes.input),
          child: TextField(
            key: const Key('quickSendField'),
            controller: _ctrl,
            focusNode: _focus,
            minLines: 1,
            maxLines: 4,
            style: Theme.of(context).textTheme.bodyMedium,
            textInputAction: TextInputAction.send,
            onSubmitted: (_) => _send(),
            decoration: InputDecoration(
              hintText: '快速发送消息…',
              filled: true,
              fillColor: useFloatingGlass ? c.fill.withValues(alpha: 0.42) : null,
              constraints: const BoxConstraints(minHeight: Sizes.input),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(Sizes.input / 2), borderSide: BorderSide.none),
              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(Sizes.input / 2), borderSide: BorderSide.none),
              focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(Sizes.input / 2), borderSide: BorderSide(color: c.accent, width: 1.5)),
              contentPadding: const EdgeInsets.symmetric(horizontal: Gap.l + 2, vertical: (Sizes.input - 20) / 2),
            ),
          ),
        ),
      ),
      const SizedBox(width: Gap.s),
      SizedBox.square(
        dimension: Sizes.input,
        child: IconButton(
          key: const Key('quickSendButton'),
          style: IconButton.styleFrom(
            fixedSize: const Size.square(Sizes.input),
            shape: const CircleBorder(),
            backgroundColor: empty ? c.fill : c.accent,
            foregroundColor: empty ? c.text3 : Colors.white,
          ),
          icon: const Icon(CupertinoIcons.arrow_up, size: Sizes.iconMd),
          tooltip: '发送',
          onPressed: _send,
        ),
      ),
    ]);

    if (useFloatingGlass) {
      return SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Gap.xl, Gap.xs, Gap.xl, Gap.m),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 660),
              child: Glass(
                radius: 26,
                padding: const EdgeInsets.symmetric(horizontal: Gap.s + 2, vertical: Gap.s),
                child: Material(type: MaterialType.transparency, child: row),
              ),
            ),
          ),
        ),
      );
    }

    // 常规底栏（非悬浮或关闭玻璃时）
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
              child: row,
            ),
          ),
        ),
      ),
    );
  }
}
