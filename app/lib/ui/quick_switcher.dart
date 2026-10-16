import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'tokens.dart';

import '../models/block.dart';
import '../pages/doc.dart';
import '../pages/inline_md.dart';
import '../sync/sync_client.dart';
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
      barrierColor: Colors.black38,
      transitionDuration: Motion.medium4,
      pageBuilder: (c, _, _) => _QuickSwitcher(sync: sync),
      transitionBuilder: (c, a, _, child) {
        final t = CurvedAnimation(parent: a, curve: Curves.easeOutCubic);
        final sp = CurvedAnimation(parent: a, curve: springCurve, reverseCurve: Curves.easeIn);
        return FadeTransition(opacity: t, child: ScaleTransition(scale: Tween(begin: 0.9, end: 1.0).animate(sp), child: child));
      },
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
    final cs = Theme.of(context).colorScheme;
    final results = searchAll(widget.sync, _q);
    final sel = results.isEmpty ? 0 : _sel.clamp(0, results.length - 1);
    return Align(
      alignment: const Alignment(0, -0.6),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Glass(
          key: const Key('quickSwitcher'),
          radius: 22,
          strong: true,
          child: Material(
          type: MaterialType.transparency,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560, maxHeight: 460),
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
                child: TextField(
                  key: const Key('switcherField'),
                  autofocus: true,
                  onChanged: (v) => setState(() {
                    _q = v;
                    _sel = 0;
                  }),
                  onSubmitted: (_) {
                    if (results.isNotEmpty) Navigator.pop(context, results[sel].target);
                  },
                  decoration: InputDecoration(
                    prefixIcon: const Icon(CupertinoIcons.search),
                    hintText: '搜索页面和内容…',
                    border: InputBorder.none,
                    contentPadding: const EdgeInsets.symmetric(vertical: 18),
                    suffixIcon: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text('Esc', style: TextStyle(color: cs.outline, fontSize: 12)),
                    ),
                  ),
                ),
              ),
              Divider(height: 1, color: cs.outlineVariant),
              Flexible(
                child: results.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.all(28),
                        child: Text(_q.isEmpty ? '还没有页面' : '没有找到 "$_q"', style: TextStyle(color: cs.outline)),
                      )
                    : ListView.builder(
                        shrinkWrap: true,
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        itemCount: results.length,
                        itemBuilder: (c, i) {
                          final r = results[i];
                          return Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 6),
                            child: ListTile(
                              dense: true,
                              selected: i == sel,
                              selectedTileColor: cs.primary.withValues(alpha: 0.1),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                              leading: Text(r.icon, style: const TextStyle(fontSize: 20)),
                              title: Text(r.title, overflow: TextOverflow.ellipsis),
                              subtitle: Text(r.subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
                              onTap: () => Navigator.pop(context, r.target),
                            ),
                          );
                        },
                      ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                child: Row(children: [
                  Text('↑↓ 选择   ↵ 打开', style: TextStyle(fontSize: 12, color: cs.outline)),
                ]),
              ),
            ]),
          ),
          ),
        ),
      ),
    );
  }
}
