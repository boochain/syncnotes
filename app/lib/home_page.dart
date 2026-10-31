import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
  final _searchFocus = FocusNode();
  final _picked = <String>{};
  var _picking = false;
  String? _openId;
  String _view = 'all';
  String? _folderId;
  String? _tag;
  String _sort = 'updated';

  @override
  void dispose() {
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _open(BuildContext context, Note n) {
    if (_picking) {
      setState(() => _picked.contains(n.id) ? _picked.remove(n.id) : _picked.add(n.id));
      return;
    }
    if (n.folder) {
      setState(() {
        _view = 'folder';
        _folderId = n.id;
        _tag = null;
      });
      return;
    }
    final wide = MediaQuery.sizeOf(context).width >= 800;
    if (wide) {
      setState(() => _openId = n.id);
      return;
    }
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => EditorPage(noteId: n.id)));
  }

  void _trashWithUndo(Session s, Note n) {
    s.trashNote(n);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('「${n.heading}」已放进回收站'),
      action: SnackBarAction(label: '撤销', onPressed: () => s.restoreNote(n)),
    ));
  }

  Future<bool> _confirm(String title, String body) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('确定')),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _renameFolder(Session s, Note folder) async {
    final name = TextEditingController(text: folder.title);
    var icon = folder.icon;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          title: const Text('文件夹'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: name, decoration: const InputDecoration(labelText: '名称')),
            const SizedBox(height: 12),
            Wrap(spacing: 4, children: [
              for (final e in folderIcons)
                ChoiceChip(label: Text(e.isEmpty ? '无' : e), selected: icon == e, onSelected: (_) => setLocal(() => icon = e)),
            ]),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('保存')),
          ],
        ),
      ),
    );
    if (ok == true) {
      folder.title = name.text.trim();
      folder.icon = icon;
      s.touch(folder);
    }
    name.dispose();
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
      onFolder: (folder) => _renameFolder(s, folder),
    );
    final body = Column(children: [
      if (s.error != null)
        Material(
          color: Theme.of(context).colorScheme.errorContainer,
          child: ListTile(
            dense: true,
            title: Text(s.error!),
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              TextButton(onPressed: s.sync, child: const Text('重试')),
              IconButton(onPressed: s.clearError, icon: const Icon(Icons.close)),
            ]),
          ),
        )
      else
        ListTile(
          dense: true,
          title: Text(s.syncing ? '正在同步' : (s.live ? '已连上' : '还没连上')),
          subtitle: Text(s.lastSyncAt == null ? '下拉可以再同步一次' : '上次同步 ${relativeTime(s.lastSyncAt!, DateTime.now())}'),
          trailing: s.syncing ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : null,
        ),
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
        child: _view == 'tasks'
            ? _taskList(s)
            : RefreshIndicator(
                onRefresh: s.sync,
                child: shown.isEmpty
                    ? ListView(children: [
                        const SizedBox(height: 120),
                        Center(child: Text(_view == 'trash' ? '回收站是空的' : '这里还没有笔记')),
                        const SizedBox(height: 12),
                        if (_view != 'trash') Center(child: FilledButton(onPressed: () => _newNote(s), child: const Text('写第一篇'))),
                      ])
                    : ListView.separated(
                        itemCount: shown.length + (_view == 'trash' ? 1 : 0),
                        separatorBuilder: (_, _) => const Divider(height: 1),
                        itemBuilder: (context, i) {
                          if (_view == 'trash' && i == shown.length) {
                            return ListTile(
                              title: const Text('清空回收站'),
                              onTap: () async {
                                if (await _confirm('清空回收站', '里面的笔记会彻底删掉，不能撤销。')) {
                                  final gone = s.notes.where((n) => n.trashed).toList();
                                  for (final n in gone) {
                                    await s.remove(n);
                                  }
                                }
                              },
                            );
                          }
                          final n = shown[i];
                          final tasks = taskProgress(n.body);
                          final when = relativeTime(n.updatedAt, DateTime.now());
                          final subtitle = tasks.total > 0 ? '$when · ${tasks.done}/${tasks.total}' : when;
                          final tile = ListTile(
                            key: ValueKey('tile-${n.id}'),
                            selected: _openId == n.id,
                            leading: _picking
                                ? Checkbox(value: _picked.contains(n.id), onChanged: (_) => _open(context, n))
                                : Text((n.icon.isEmpty ? (n.pinned ? '📌' : '📝') : n.icon), style: const TextStyle(fontSize: 20)),
                            title: Text(n.heading),
                            subtitle: Text(subtitle),
                            trailing: _view == 'trash'
                                ? Row(mainAxisSize: MainAxisSize.min, children: [
                                    IconButton(tooltip: '恢复', onPressed: () => s.restoreNote(n), icon: const Icon(Icons.restore)),
                                    IconButton(
                                      tooltip: '彻底删除',
                                      onPressed: () async {
                                        if (await _confirm('彻底删除', '「${n.heading}」删掉后不能恢复。')) await s.remove(n);
                                      },
                                      icon: const Icon(Icons.delete_forever),
                                    ),
                                  ])
                                : null,
                            onTap: () => _open(context, n),
                            onLongPress: () => _menu(s, n),
                          );
                          if (_view == 'trash') return tile;
                          return Dismissible(
                            key: ValueKey(n.id),
                            direction: DismissDirection.endToStart,
                            background: Container(
                              color: Theme.of(context).colorScheme.errorContainer,
                              alignment: Alignment.centerRight,
                              padding: const EdgeInsets.only(right: 16),
                              child: const Icon(Icons.delete_outline),
                            ),
                            confirmDismiss: (_) async {
                              _trashWithUndo(s, n);
                              return true;
                            },
                            child: tile,
                          );
                        },
                      ),
              ),
      ),
    ]);
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyN, control: true): () => _newNote(s),
        const SingleActivator(LogicalKeyboardKey.keyF, control: true): _searchFocus.requestFocus,
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
      drawer: wide ? null : Drawer(child: SafeArea(child: sidebar)),
      appBar: AppBar(
        title: _picking
            ? Text('已选 ${_picked.length}')
            : TextField(
                focusNode: _searchFocus,
                controller: _search,
                decoration: const InputDecoration(hintText: '搜索标题、正文、标签', border: InputBorder.none, prefixIcon: Icon(Icons.search)),
                onChanged: (_) => setState(() {}),
              ),
        actions: [
          if (_picking) ...[
            IconButton(
              tooltip: '移到回收站',
              onPressed: () {
                for (final id in _picked.toList()) {
                  final hit = s.notes.where((e) => e.id == id);
                  if (hit.isNotEmpty) _trashWithUndo(s, hit.first);
                }
                setState(() {
                  _picked.clear();
                  _picking = false;
                });
              },
              icon: const Icon(Icons.delete_outline),
            ),
            IconButton(
              tooltip: '取消选择',
              onPressed: () => setState(() {
                _picked.clear();
                _picking = false;
              }),
              icon: const Icon(Icons.close),
            ),
          ] else ...[
            IconButton(tooltip: '多选', onPressed: () => setState(() => _picking = true), icon: const Icon(Icons.checklist)),
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
        ],
      ),
      floatingActionButton: _view == 'trash' || _picking
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
      body: wide
          ? Row(children: [
              SizedBox(width: 220, child: sidebar),
              const VerticalDivider(width: 1),
              SizedBox(width: 340, child: body),
              const VerticalDivider(width: 1),
              Expanded(child: _openId == null ? const Center(child: Text('选一篇笔记，就在右边写')) : EditorPage(key: ValueKey(_openId), noteId: _openId!)),
            ])
          : body,
        ),
      ),
    );
  }

  Widget _taskList(Session s) {
    final tasks = openTasks(s.notes);
    if (tasks.isEmpty) return const Center(child: Text('没有未完成的待办'));
    return ListView.separated(
      itemCount: tasks.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, i) {
        final t = tasks[i];
        return ListTile(
          leading: const Icon(Icons.check_box_outline_blank),
          title: Text(t.text),
          subtitle: Text(t.title),
          onTap: () {
            Note? n;
            for (final e in s.notes) {
              if (e.id == t.noteId) n = e;
            }
            if (n != null) _open(context, n);
          },
        );
      },
    );
  }

  Future<void> _menu(Session s, Note n) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(title: Text(n.pinned ? '取消置顶' : '置顶'), onTap: () => Navigator.pop(context, 'pin')),
          ListTile(title: const Text('移动到文件夹'), onTap: () => Navigator.pop(context, 'move')),
          ListTile(title: const Text('再复制一篇'), onTap: () => Navigator.pop(context, 'dup')),
          ListTile(title: const Text('移到回收站'), onTap: () => Navigator.pop(context, 'trash')),
        ]),
      ),
    );
    if (!mounted || action == null) return;
    if (action == 'pin') {
      n.pinned = !n.pinned;
      s.touch(n);
    }
    if (action == 'dup') s.duplicate(n);
    if (action == 'trash') _trashWithUndo(s, n);
    if (action == 'move') {
      final folders = folderNotes(s.notes);
      if (!mounted) return;
      final id = await showDialog<String>(
        context: context,
        builder: (context) => SimpleDialog(
          title: const Text('移动到'),
          children: [
            SimpleDialogOption(onPressed: () => Navigator.pop(context, ''), child: const Text('不放入文件夹')),
            for (final f in folders) SimpleDialogOption(onPressed: () => Navigator.pop(context, f.id), child: Text('${f.icon} ${f.heading}')),
          ],
        ),
      );
      if (id == null) return;
      n.folderId = id.isEmpty ? null : id;
      s.touch(n);
    }
  }
}

class _Sidebar extends StatelessWidget {
  const _Sidebar({required this.view, required this.folderId, required this.tag, required this.onSelect, required this.onFolder});
  final String view;
  final String? folderId;
  final String? tag;
  final void Function(String view, {String? folder, String? tag}) onSelect;
  final void Function(Note folder) onFolder;

  @override
  Widget build(BuildContext context) {
    final notes = Scope.of(context).notes;
    final folders = folderNotes(notes);
    final tags = allTags(notes);
    final todo = openTasks(notes).length;
    return ListView(children: [
      ListTile(selected: view == 'all', leading: const Icon(Icons.inbox), title: const Text('全部'), onTap: () => onSelect('all')),
      ListTile(selected: view == 'pinned', leading: const Icon(Icons.push_pin), title: const Text('置顶'), onTap: () => onSelect('pinned')),
      ListTile(selected: view == 'tasks', leading: const Icon(Icons.check_box_outlined), title: Text('待办${todo == 0 ? '' : ' $todo'}'), onTap: () => onSelect('tasks')),
      const Divider(),
      const ListTile(dense: true, title: Text('文件夹  长按可以改名')),
      for (final f in folders)
        ListTile(
          selected: view == 'folder' && folderId == f.id,
          contentPadding: EdgeInsets.only(left: f.folderId == null ? 16 : 32, right: 16),
          leading: Text(f.icon.isEmpty ? '📁' : f.icon, style: const TextStyle(fontSize: 18)),
          title: Text(f.heading),
          trailing: Text('${folderCount(notes, f.id)}'),
          onTap: () => onSelect('folder', folder: f.id),
          onLongPress: () => onFolder(f),
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
