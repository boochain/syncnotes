import 'package:flutter/material.dart';

import 'desktop.dart';
import 'editor_page.dart';
import 'library.dart';
import 'scope.dart';
import 'session.dart';
import 'settings_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => HomePageState();
}

class HomePageState extends State<HomePage> {
  final _search = TextEditingController();
  String _view = 'all';
  String? _folderId;
  String? _tag;
  String _sort = 'updated';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _open(BuildContext context, Note n) {
    if (n.folder) {
      setState(() {
        _view = 'folder';
        _folderId = n.id;
        _tag = null;
      });
      return;
    }
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => EditorPage(noteId: n.id)));
  }

  Future<void> _newFolder(Session s) async {
    final name = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('新建文件夹'),
        content: TextField(controller: name, autofocus: true, decoration: const InputDecoration(hintText: '名称')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('创建')),
        ],
      ),
    );
    if (ok == true && name.text.trim().isNotEmpty) {
      final folder = s.create(title: name.text.trim(), folder: true, folderId: _view == 'folder' ? _folderId : null);
      setState(() {
        _view = 'folder';
        _folderId = folder.id;
      });
    }
    name.dispose();
  }

  void _newNote(Session s, {String body = ''}) {
    final folder = _view == 'folder' ? _folderId : null;
    final n = s.create(folderId: folder, body: body);
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => EditorPage(noteId: n.id)));
  }

  void _daily(Session s) {
    final title = dailyTitle(DateTime.now());
    final existing = noteByTitle(s.notes, title);
    final n = existing ?? s.create(title: title, body: noteTemplates['日记']!);
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => EditorPage(noteId: n.id)));
  }

  @override
  Widget build(BuildContext context) {
    final s = Scope.of(context);
    final shown = selectNotes(s.notes, view: _view, folderId: _folderId, tag: _tag, query: _search.text, sort: _sort);
    final wide = MediaQuery.sizeOf(context).width >= 800;
    final sidebar = _Sidebar(
      view: _view,
      folderId: _folderId,
      tag: _tag,
      onSelect: (view, {folder, tag}) => setState(() {
        _view = view;
        _folderId = folder;
        _tag = tag;
      }),
    );
    final body = Column(children: [
      if (s.error != null) Material(color: Theme.of(context).colorScheme.errorContainer, child: ListTile(dense: true, title: Text(s.error!))),
      ValueListenableBuilder<Transfer?>(
        valueListenable: s.transfer,
        builder: (context, t, _) {
          if (t == null) return const SizedBox.shrink();
          final label = t.error ?? (t.waiting ? '正在确认，等服务器回复' : '正在传输');
          return ListTile(
            title: Text(t.name, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(t.error ?? '$label  ${_pct(t)}', maxLines: 2),
            trailing: t.error == null
                ? SizedBox(width: 72, child: LinearProgressIndicator(value: t.waiting ? null : t.fraction))
                : IconButton(onPressed: s.dismissTransfer, icon: const Icon(Icons.close)),
          );
        },
      ),
      Expanded(
        child: shown.isEmpty
            ? Center(child: Text(_view == 'trash' ? '回收站是空的' : '这里还没有笔记'))
            : ListView.separated(
                itemCount: shown.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, i) {
                  final n = shown[i];
                  final tasks = taskProgress(n.body);
                  final subtitle = tasks.total > 0 ? '${tasks.done}/${tasks.total}  ${n.body.trim()}' : n.body.trim();
                  return ListTile(
                    key: ValueKey(n.id),
                    leading: Icon(n.pinned ? Icons.push_pin : Icons.notes),
                    title: Text(n.heading),
                    subtitle: subtitle.isEmpty ? null : Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
                    trailing: _view == 'trash'
                        ? Row(mainAxisSize: MainAxisSize.min, children: [
                            IconButton(tooltip: '恢复', onPressed: () => s.restoreNote(n), icon: const Icon(Icons.restore)),
                            IconButton(tooltip: '彻底删除', onPressed: () => s.remove(n), icon: const Icon(Icons.delete_forever)),
                          ])
                        : null,
                    onTap: () => _open(context, n),
                  );
                },
              ),
      ),
    ]);
    return Scaffold(
      drawer: wide ? null : Drawer(child: SafeArea(child: sidebar)),
      appBar: AppBar(
        title: TextField(
          controller: _search,
          decoration: const InputDecoration(hintText: '搜索标题、正文、标签', border: InputBorder.none, prefixIcon: Icon(Icons.search)),
          onChanged: (_) => setState(() {}),
        ),
        actions: [
          PopupMenuButton<String>(
            tooltip: '排序',
            onSelected: (v) => setState(() => _sort = v),
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'updated', child: Text('最近修改')),
              PopupMenuItem(value: 'created', child: Text('最近创建')),
              PopupMenuItem(value: 'title', child: Text('标题')),
            ],
          ),
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
          IconButton(tooltip: '设置', onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SettingsPage())), icon: const Icon(Icons.settings)),
        ],
      ),
      floatingActionButton: _view == 'trash'
          ? null
          : PopupMenuButton<String>(
              tooltip: '新建',
              onSelected: (v) {
                if (v == 'note') _newNote(s);
                if (v == 'folder') _newFolder(s);
                if (v == 'daily') _daily(s);
                if (noteTemplates.containsKey(v)) _newNote(s, body: noteTemplates[v]!);
              },
              itemBuilder: (_) => [
                const PopupMenuItem(value: 'note', child: Text('新建笔记')),
                const PopupMenuItem(value: 'folder', child: Text('新建文件夹')),
                const PopupMenuItem(value: 'daily', child: Text('今日笔记')),
                const PopupMenuDivider(),
                for (final name in noteTemplates.keys) PopupMenuItem(value: name, child: Text('模板：$name')),
              ],
              child: const CircleAvatar(radius: 28, child: Icon(Icons.add)),
            ),
      body: wide ? Row(children: [SizedBox(width: 240, child: sidebar), const VerticalDivider(width: 1), Expanded(child: body)]) : body,
    );
  }
}

class _Sidebar extends StatelessWidget {
  const _Sidebar({required this.view, required this.folderId, required this.tag, required this.onSelect});
  final String view;
  final String? folderId;
  final String? tag;
  final void Function(String view, {String? folder, String? tag}) onSelect;

  @override
  Widget build(BuildContext context) {
    final notes = Scope.of(context).notes;
    final folders = folderNotes(notes);
    final tags = allTags(notes);
    return ListView(children: [
      ListTile(selected: view == 'all', leading: const Icon(Icons.inbox), title: const Text('全部'), onTap: () => onSelect('all')),
      ListTile(selected: view == 'pinned', leading: const Icon(Icons.push_pin), title: const Text('置顶'), onTap: () => onSelect('pinned')),
      const Divider(),
      const ListTile(dense: true, title: Text('文件夹')),
      for (final f in folders)
        ListTile(
          selected: view == 'folder' && folderId == f.id,
          contentPadding: EdgeInsets.only(left: f.folderId == null ? 16 : 32, right: 16),
          leading: const Icon(Icons.folder),
          title: Text(f.heading),
          onTap: () => onSelect('folder', folder: f.id),
        ),
      const Divider(),
      const ListTile(dense: true, title: Text('标签')),
      for (final t in tags)
        ListTile(
          selected: view == 'tag' && tag == t,
          leading: const Icon(Icons.tag),
          title: Text(t),
          onTap: () => onSelect('tag', tag: t),
        ),
      const Divider(),
      ListTile(selected: view == 'trash', leading: const Icon(Icons.delete_outline), title: const Text('回收站'), onTap: () => onSelect('trash')),
    ]);
  }
}

String _pct(Transfer t) {
  if (t.waiting) return '确认中';
  if (t.total <= 0) return '';
  final p = (100 * t.done / t.total).clamp(0, 99);
  return '${p.toStringAsFixed(0)}%';
}
