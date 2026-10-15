import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../blocks/block_type.dart';
import '../models/block.dart';
import 'block_card.dart';

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
    final first = text.split('\n').first;
    AppScope.of(context).sync.create(
          kind: BlockKind.message,
          title: first.length > 40 ? '${first.substring(0, 40)}…' : first,
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
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: cs.surfaceContainer,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
          child: Row(children: [
            IconButton(
              icon: const Icon(Icons.add_circle_outline),
              tooltip: '新建',
              onPressed: () => showCreateMenu(context, parentId: widget.parentId),
            ),
            Expanded(
              child: TextField(
                key: const Key('quickSendField'),
                controller: _ctrl,
                focusNode: _focus,
                minLines: 1,
                maxLines: 4,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => _send(),
                decoration: InputDecoration(
                  hintText: '快速发送消息…',
                  isDense: true,
                  filled: true,
                  fillColor: cs.surfaceContainerHighest,
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                ),
              ),
            ),
            const SizedBox(width: 4),
            IconButton.filled(
              key: const Key('quickSendButton'),
              icon: const Icon(Icons.send),
              tooltip: '发送',
              onPressed: _send,
            ),
          ]),
        ),
      ),
    );
  }
}
