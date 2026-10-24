import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'motion.dart';
import 'tokens.dart';

import '../models/block.dart';
import '../pages/doc.dart';
import '../pages/inline_md.dart';
import '../sync/sync_client.dart';
import 'ds.dart';
import 'glass.dart';

class SwitcherResult {
  final Block target; // 要打开的页面 / 收件箱条目
  final String title;
  final String subtitle;
  final String icon;
  SwitcherResult(this.target, this.title, this.subtitle, this.icon);
}

/// 搜索所有页面标题与内容、收件箱条目。
List<SwitcherResult> searchAll(SyncClient sync, String q) {
  final query = q.trim().toLowerCase();
  final out = <SwitcherResult>[];
  final seen = <String>{};
  Block? pageOf(Block b) {
    var cur = b;
    final guard = <String>{};
    while (cur.kind != BlockKind.page && cur.parentId != null && guard.add(cur.id)) {
      final p = sync.byId(cur.parentId!);
      if (p == null) return null;
      cur = p;
    }
    return cur.kind == BlockKind.page ? cur : null;
  }

  String icon(Block p) => (p.payload['icon'] ?? '📄') as String;
  final all = sync.blocks;
  // 页面标题优先
  for (final b in all.where((b) => b.kind == BlockKind.page)) {
    if (query.isEmpty || b.title.toLowerCase().contains(query)) {
      if (seen.add(b.id)) out.add(SwitcherResult(b, b.title.isEmpty ? '无标题' : b.title, '页面', icon(b)));
    }
  }
  if (query.isEmpty) return out.take(20).toList();
  // 页面内容
  for (final b in all.where((b) => b.kind == BlockKind.text)) {
    final t = plainInline(docText(b));
    final i = t.toLowerCase().indexOf(query);
    if (i < 0) continue;
    final p = pageOf(b);
    if (p == null || p.deleted || !seen.add('${p.id}:${b.id}')) continue;
    final start = (i - 12).clamp(0, t.length);
    final snippet = '${start > 0 ? '…' : ''}${t.substring(start, (i + query.length + 24).clamp(0, t.length))}';
    out.add(SwitcherResult(p, p.title.isEmpty ? '无标题' : p.title, snippet, icon(p)));
  }
  // 收件箱条目
  for (final b in all.where((b) => b.kind == BlockKind.message || b.kind == BlockKind.note || b.kind == BlockKind.file)) {
    final hay = '${b.title} ${b.payload['text'] ?? ''} ${b.payload['markdown'] ?? ''}'.toLowerCase();
    if (hay.contains(query) && seen.add(b.id)) {
      final ic = switch (b.kind) { BlockKind.message => '💬', BlockKind.file => '📎', _ => '📝' };
      out.add(SwitcherResult(b, b.title, '收件箱', ic));
    }
  }
  return out.take(50).toList();
}

/// Ctrl+K 快速切换器
Future<Block?> showQuickSwitcher(BuildContext context, SyncClient sync) => showGeneralDialog<Block>(
      context: context,
      barrierDismissible: true,
      barrierLabel: '关闭',
      barrierColor: Colors.black26,
      transitionDuration: Motion.short4,
      pageBuilder: (c, _, _) => _QuickSwitcher(sync: sync),
      transitionBuilder: (_, animation, _, child) => MotionFade(animation: animation, child: child),
    );

class _QuickSwitcher extends StatefulWidget {
  final SyncClient sync;
  const _QuickSwitcher({required this.sync});
  @override
  State<_QuickSwitcher> createState() => _QuickSwitcherState();
}

class _QuickSwitcherState extends State<_QuickSwitcher> {
  String _q = '';
  int _sel = 0;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final tt = Theme.of(context).textTheme;
    final results = searchAll(widget.sync, _q);
    final sel = results.isEmpty ? 0 : _sel.clamp(0, results.length - 1);
    final h = MediaQuery.sizeOf(context).height;
    // 快速查找（照 Notion / Spotlight）：搜索行 44，结果行 44（emoji 20 + 标题 / 摘要），底部提示 32
    return Align(
      alignment: h < 500 ? Alignment.topCenter : const Alignment(0, -0.6),
      child: Padding(
        padding: const EdgeInsets.all(Gap.l),
        child: Glass(
          key: const Key('quickSwitcher'),
          radius: AppRadius.l,
          child: Material(
            type: MaterialType.transparency,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: 560, maxHeight: (h - 2 * Gap.l).clamp(120.0, 460.0)),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Focus(
                  onKeyEvent: (n, e) {
                    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
                    if (e.logicalKey == LogicalKeyboardKey.arrowDown) {
                      setState(() => _sel = results.isEmpty ? 0 : (sel + 1) % results.length);
                      return KeyEventResult.handled;
                    }
                    if (e.logicalKey == LogicalKeyboardKey.arrowUp) {
                      setState(() => _sel = results.isEmpty ? 0 : (sel - 1 + results.length) % results.length);
                      return KeyEventResult.handled;
                    }
                    return KeyEventResult.ignored;
                  },
                  child: SizedBox(
                    height: Sizes.bar,
                    child: Row(children: [
                      const SizedBox(width: Gap.l),
                      Icon(CupertinoIcons.search, size: Sizes.iconMd, color: c.text3),
                      const SizedBox(width: Gap.m),
                      Expanded(
                        child: TextField(
                          key: const Key('switcherField'),
                          autofocus: true,
                          style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w400),
                          onChanged: (v) => setState(() {
                            _q = v;
                            _sel = 0;
                          }),
                          onSubmitted: (_) {
                            if (results.isNotEmpty) Navigator.pop(context, results[sel].target);
                          },
                          decoration: const InputDecoration(
                            hintText: '搜索页面和内容…',
                            filled: false,
                            border: InputBorder.none,
                            enabledBorder: InputBorder.none,
                            focusedBorder: InputBorder.none,
                            contentPadding: EdgeInsets.zero,
                          ),
                        ),
                      ),
                      _Kbd('Esc'),
                      const SizedBox(width: Gap.l),
                    ]),
                  ),
                ),
                Divider(height: 1, color: c.separator),
                Flexible(
                  child: results.isEmpty
                      ? Padding(
                          padding: const EdgeInsets.all(Gap.x3),
                          child: Text(_q.isEmpty ? '还没有页面' : '没有找到 "$_q"',
                              key: const Key('switcherEmpty'), textAlign: TextAlign.center, style: tt.bodyMedium?.copyWith(color: c.text3)),
                        )
                      : ListView.builder(
                          shrinkWrap: true,
                          padding: const EdgeInsets.all(Gap.xs),
                          itemCount: results.length,
                          itemBuilder: (ctx, i) {
                            final r = results[i];
                            return InkWell(
                              key: ValueKey('switch-$i'),
                              borderRadius: BorderRadius.circular(AppRadius.s),
                              onTap: () => Navigator.pop(context, r.target),
                              child: Container(
                                // 最小 44：大字号时自动增高
                                constraints: const BoxConstraints(minHeight: Sizes.bar),
                                padding: const EdgeInsets.symmetric(horizontal: Gap.m),
                                decoration: BoxDecoration(
                                  color: i == sel ? c.selected : Colors.transparent,
                                  borderRadius: BorderRadius.circular(AppRadius.s),
                                ),
                                child: Row(children: [
                                  Emoji(r.icon, size: Sizes.iconMd),
                                  const SizedBox(width: Gap.m),
                                  Expanded(
                                    child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                                      Text(r.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: tt.bodyMedium?.copyWith(color: c.text, height: 1.25)),
                                      Text(r.subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: tt.bodySmall?.copyWith(color: c.text3, height: 1.25)),
                                    ]),
                                  ),
                                  if (i == sel) Icon(CupertinoIcons.arrow_turn_down_left, size: Sizes.iconSm, color: c.text3),
                                ]),
                              ),
                            );
                          },
                        ),
                ),
                Divider(height: 1, color: c.separator),
                ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: Sizes.control),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: Gap.l, vertical: Gap.xs),
                    child: Row(children: [
                      Flexible(child: Text('↑↓ 选择   ↵ 打开', maxLines: 1, overflow: TextOverflow.ellipsis, style: tt.bodySmall?.copyWith(color: c.text3))),
                    ]),
                  ),
                ),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

/// 键帽提示
class _Kbd extends StatelessWidget {
  final String label;
  const _Kbd(this.label);
  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Container(
      height: 20,
      padding: const EdgeInsets.symmetric(horizontal: Gap.s),
      alignment: Alignment.center,
      decoration: BoxDecoration(border: Border.all(color: c.separator), borderRadius: BorderRadius.circular(AppRadius.xs)),
      child: Text(label, textScaler: TextScaler.noScaling, style: TextStyle(fontSize: 12, height: 1.0, color: c.text3)),
    );
  }
}
