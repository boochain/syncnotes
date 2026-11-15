import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../blocks/block_type.dart';
import '../models/block.dart';
import 'block_card.dart';
import 'ds.dart';

/// 底部快速发送消息栏。
class QuickSendBar extends StatefulWidget {
  final String? parentId;
  const QuickSendBar({super.key, this.parentId});
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
    // 发送栏（照 Apple 信息 App）：+ / 输入框 / 发送 三者同为 36 高、底部对齐（多行时按钮留在最后一行）
    return Material(
      color: c.bg,
      child: Container(
        decoration: BoxDecoration(border: Border(top: BorderSide(color: c.separator))),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: Gap.m, vertical: Gap.m),
            child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
              SizedBox.square(
                dimension: Sizes.input,
                child: IconButton(
                  key: const Key('quickNewButton'),
                  style: IconButton.styleFrom(fixedSize: const Size.square(Sizes.input), shape: const CircleBorder()),
                  icon: const Icon(CupertinoIcons.add, size: Sizes.iconMd),
                  tooltip: '新建',
                  onPressed: () => showCreateMenu(context, parentId: widget.parentId),
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
            ]),
          ),
        ),
      ),
    );
  }
}
