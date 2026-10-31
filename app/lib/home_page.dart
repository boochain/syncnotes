import 'package:flutter/material.dart';

import 'desktop.dart';
import 'editor_page.dart';
import 'scope.dart';
import 'session.dart';
import 'settings_page.dart';

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    final s = Scope.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('SyncNotes'),
        actions: [
          if (isDesktop)
            IconButton(
              tooltip: s.windowExpanded ? '收起为小窗' : '展开窗口',
              onPressed: () async {
                final next = !s.windowExpanded;
                s.windowExpanded = next;
                await Desk.toggle(next);
              },
              icon: Icon(s.windowExpanded ? Icons.close_fullscreen : Icons.open_in_full),
            ),
          IconButton(
            tooltip: '设置',
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SettingsPage())),
            icon: const Icon(Icons.settings),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        key: const Key('newNote'),
        onPressed: () {
          final n = s.create();
          Navigator.of(context).push(MaterialPageRoute(builder: (_) => EditorPage(noteId: n.id)));
        },
        child: const Icon(Icons.add),
      ),
      body: Column(children: [
        if (s.error != null)
          Material(color: Theme.of(context).colorScheme.errorContainer, child: ListTile(dense: true, title: Text(s.error!))),
        ValueListenableBuilder<Transfer?>(
          valueListenable: s.transfer,
          builder: (context, t, _) {
            if (t == null) return const SizedBox.shrink();
            final label = t.error ?? (t.waiting ? '正在确认，等服务器回复' : '正在传输');
            return ListTile(
              title: Text(t.name, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(t.error == null ? '$label  ${_pct(t)}' : t.error!, maxLines: 2),
              trailing: t.error == null
                  ? SizedBox(width: 72, child: LinearProgressIndicator(value: t.waiting ? null : t.fraction))
                  : IconButton(onPressed: s.dismissTransfer, icon: const Icon(Icons.close)),
            );
          },
        ),
        Expanded(
          child: s.notes.isEmpty
              ? const Center(child: Text('还没有笔记'))
              : ListView.separated(
                  itemCount: s.notes.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, i) {
                    final n = s.notes[i];
                    return ListTile(
                      key: ValueKey(n.id),
                      title: Text(n.heading),
                      subtitle: n.body.trim().isEmpty ? null : Text(n.body.trim(), maxLines: 1, overflow: TextOverflow.ellipsis),
                      onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => EditorPage(noteId: n.id))),
                    );
                  },
                ),
        ),
      ]),
    );
  }
}

String _pct(Transfer t) {
  if (t.waiting) return '确认中';
  if (t.total <= 0) return '';
  final p = (100 * t.done / t.total).clamp(0, 99);
  return '${p.toStringAsFixed(0)}%';
}
