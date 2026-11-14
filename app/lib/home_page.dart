import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'desktop.dart';
import 'device.dart';
import 'editor_page.dart';
import 'graph_page.dart';
import 'library.dart';
import 'scope.dart';
import 'session.dart';
import 'settings_page.dart';
import 'ui/tokens.dart';

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
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 20), (_) => _ping());
    WidgetsBinding.instance.addPostFrameCallback((_) => _ping());
  }

  void _ping() {
    if (!mounted) return;
    final s = Scope.of(context);
    final due = dueNotes(s.notes, DateTime.now().millisecondsSinceEpoch);
    for (final n in due) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('提醒：${n.heading}')));
      unawaited(Device.notify(n.heading, n.body.split('\n').first));
      n.remindAt = null;
      s.touch(n);
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final n in s.notes) {
      final at = n.remindAt;
      if (at != null && at > now) {
        unawaited(Device.scheduleReminder(at, n.heading, n.body.split('\n').first, n.id.hashCode));
      }
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
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

  Future<void> _switcher(Session s) async {
    final box = TextEditingController();
    final picked = await showDialog<Note>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('跳到笔记'),
        content: SizedBox(
          width: 420,
          child: StatefulBuilder(
            builder: (context, setLocal) {
              final hits = selectNotes(s.notes, view: 'all', query: box.text).take(12).toList();
              return Column(mainAxisSize: MainAxisSize.min, children: [
                TextField(
                  controller: box,
                  autofocus: true,
                  decoration: const InputDecoration(hintText: '输入标题或正文'),
                  onChanged: (_) => setLocal(() {}),
                ),
                const SizedBox(height: 8),
                for (final n in hits)
                  ListTile(
                    dense: true,
                    title: Text(n.heading, maxLines: 1, overflow: TextOverflow.ellipsis),
                    onTap: () => Navigator.pop(context, n),
                  ),
                if (hits.isEmpty) const ListTile(title: Text('没有匹配的笔记')),
              ]);
            },
          ),
        ),
      ),
    );
    box.dispose();
    if (picked != null && mounted) _open(context, picked);
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
    Note? openFolder;
    for (final n in s.notes) {
      if (n.id == _folderId) openFolder = n;
    }
    final shown = openFolder != null && openFolder.smart
        ? smartMatches(s.notes, openFolder.smartQuery)
        : selectNotes(s.notes, view: _view, folderId: _folderId, tag: _tag, query: _search.text, sort: _sort);
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
      onDrop: (noteId, folderId) {
        if (folderContains(s.notes, noteId, folderId)) return;
        final hit = s.notes.where((n) => n.id == noteId);
        if (hit.isEmpty) return;
        hit.first.folderId = folderId;
        s.touch(hit.first);
      },
      onGraph: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const GraphPage())),
    );
    final body = Column(children: [
      _StatusLine(session: s),
      if (s.pendingFingerprint != null)
        _Notice(
          text: '这台服务器的指纹和上次不一样。指纹只用来认出数据库，不是解开笔记的钥匙。确认是你自己的再记住。',
          action: '记住',
          onAction: s.acceptFingerprint,
        ),
      if (s.conflicts.isNotEmpty)
        _Notice(
          text: '${s.conflicts.length} 篇在两台设备上都被改过',
          action: '处理',
          onAction: () => _conflicts(s),
        ),
      ValueListenableBuilder<Transfer?>(
        valueListenable: s.transfer,
        builder: (context, t, _) {
          if (t == null) return const SizedBox.shrink();
          final label = t.error ?? (t.waiting ? '正在确认，等服务器回复' : (s.queued > 0 ? '正在传输，后面还有 ${s.queued} 个' : '正在传输'));
          return _Notice(
            text: t.error == null ? '${t.name} · $label ${_pct(t)}' : '${t.name} · ${t.error}',
            action: t.error == null ? null : '关闭',
            onAction: t.error == null ? null : s.dismissTransfer,
            progress: t.error == null ? (t.waiting ? null : t.fraction) : null,
            busy: t.error == null,
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
                    : ReorderableListView.builder(
                        buildDefaultDragHandles: false,
                        itemCount: shown.length + (_view == 'trash' ? 1 : 0),
                        onReorderItem: (oldIndex, newIndex) {
                          if (_view == 'trash') return;
                          applyManualOrder(shown, oldIndex, newIndex);
                          setState(() => _sort = 'order');
                          s.persistOrders(shown);
                        },
                        itemBuilder: (context, i) {
                          if (_view == 'trash' && i == shown.length) {
                            return ListTile(
                              key: const ValueKey('empty-trash'),
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
                                : ReorderableDragStartListener(index: i, child: const Icon(Icons.drag_handle)),
                            onTap: () => _open(context, n),
                            onLongPress: () => _menu(s, n),
                          );
                          return Draggable<String>(
                            key: ValueKey(n.id),
                            data: n.id,
                            feedback: Material(child: Padding(padding: const EdgeInsets.all(8), child: Text(n.heading))),
                            child: _view == 'trash' ? tile : Dismissible(
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
                          ),
                          );
                        },
                      ),
              ),
      ),
    ]);
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyN, control: true): () => _newNote(s),
        const SingleActivator(LogicalKeyboardKey.keyK, control: true): () => _switcher(s),
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
                PopupMenuItem(value: 'order', child: Text('手动顺序')),
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
                if (v == 'smart') _smart(s);
                if (noteTemplates.containsKey(v)) _newNote(s, body: noteTemplates[v]!);
              },
              itemBuilder: (_) => [
                const PopupMenuItem(value: 'note', child: Text('新建笔记')),
                const PopupMenuItem(value: 'folder', child: Text('新建文件夹')),
                const PopupMenuItem(value: 'daily', child: Text('今日笔记')),
                const PopupMenuItem(value: 'smart', child: Text('智能文件夹')),
                const PopupMenuDivider(),
                for (final name in noteTemplates.keys) PopupMenuItem(value: name, child: Text('模板：$name')),
              ],
              child: const CircleAvatar(radius: 28, child: Icon(Icons.add)),
            ),
      body: wide
          ? Row(children: [
              SizedBox(width: Tokens.sidebar, child: sidebar),
              const VerticalDivider(width: 1),
              SizedBox(width: Tokens.list, child: body),
              const VerticalDivider(width: 1),
              Expanded(child: _openId == null ? const Center(child: Text('选一篇笔记，就在右边写')) : EditorPage(key: ValueKey(_openId), noteId: _openId!, embedded: true)),
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
          ListTile(title: const Text('排到最前'), onTap: () => Navigator.pop(context, 'top')),
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
    if (action == 'top') {
      n.order = -1;
      setState(() => _sort = 'order');
      s.touch(n);
    }
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

  Future<void> _conflicts(Session s) async {
    final items = [...s.conflicts];
    for (final c in items) {
      if (!mounted) return;
      final choice = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(c.localTitle.isEmpty ? '无标题' : c.localTitle),
          content: const Text('这台设备和另一台都改过这篇。留哪边？'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, 'local'), child: const Text('留这台')),
            TextButton(onPressed: () => Navigator.pop(context, 'remote'), child: const Text('留另一台')),
            FilledButton(onPressed: () => Navigator.pop(context, 'both'), child: const Text('两边都留')),
          ],
        ),
      );
      if (choice != null) s.resolveConflict(c.id, choice);
    }
  }

  Future<void> _smart(Session s) async {
    final q = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('智能文件夹'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('会跟着条件变。可以写普通搜索，或 tag:生活、color:blue、todo。'),
          TextField(controller: q, decoration: const InputDecoration(labelText: '条件')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('建立')),
        ],
      ),
    );
    final query = q.text.trim();
    q.dispose();
    if (ok != true || query.isEmpty) return;
    final n = s.create(title: query, folder: true);
    n.smart = true;
    n.smartQuery = query;
    s.touch(n);
  }
}

class _Sidebar extends StatelessWidget {
  const _Sidebar({required this.view, required this.folderId, required this.tag, required this.onSelect, required this.onFolder, required this.onDrop, required this.onGraph});
  final String view;
  final String? folderId;
  final String? tag;
  final void Function(String view, {String? folder, String? tag}) onSelect;
  final void Function(Note folder) onFolder;
  final void Function(String noteId, String folderId) onDrop;
  final VoidCallback onGraph;

  @override
  Widget build(BuildContext context) {
    final notes = Scope.of(context).notes;
    final folders = folderNotes(notes);
    final tags = allTags(notes);
    final todo = openTasks(notes).length;
    return ListView(children: [
      ListTile(selected: view == 'all', leading: const Icon(Icons.inbox), title: const Text('全部'), onTap: () => onSelect('all')),
      ListTile(leading: const Icon(Icons.hub_outlined), title: const Text('图谱'), onTap: onGraph),
      ListTile(selected: view == 'pinned', leading: const Icon(Icons.push_pin), title: const Text('置顶'), onTap: () => onSelect('pinned')),
      ListTile(selected: view == 'tasks', leading: const Icon(Icons.check_box_outlined), title: Text('待办${todo == 0 ? '' : ' $todo'}'), onTap: () => onSelect('tasks')),
      const Divider(),
      const ListTile(dense: true, title: Text('文件夹  拖图标可以嵌套，长按改名')),
      for (final f in folders)
        DragTarget<String>(
          onWillAcceptWithDetails: (d) => d.data != f.id && !folderContains(notes, d.data, f.id),
          onAcceptWithDetails: (d) => onDrop(d.data, f.id),
          builder: (context, candidate, _) => ListTile(
            selected: view == 'folder' && folderId == f.id,
            tileColor: candidate.isEmpty ? null : Theme.of(context).colorScheme.secondaryContainer,
            contentPadding: EdgeInsets.only(left: f.folderId == null ? 16 : 32, right: 16),
            leading: Draggable<String>(
              data: f.id,
              feedback: Material(child: Padding(padding: const EdgeInsets.all(8), child: Text(f.heading))),
              child: Text(f.icon.isEmpty ? (f.smart ? '✨' : '📁') : f.icon, style: const TextStyle(fontSize: 18)),
            ),
            title: Text(f.smart ? '智能 · ${f.heading}' : f.heading),
            trailing: Text(f.smart ? '' : '${folderCount(notes, f.id)}'),
            onTap: () => onSelect('folder', folder: f.id),
            onLongPress: () => onFolder(f),
          ),
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

class _StatusLine extends StatelessWidget {
  const _StatusLine({required this.session});
  final Session session;

  @override
  Widget build(BuildContext context) {
    final s = session;
    final muted = Theme.of(context).textTheme.bodySmall;
    final label = s.error ?? (s.syncing ? '正在同步' : (s.live ? '已连上' : '未连接'));
    final when = s.lastSyncAt == null ? '下拉再同步' : '上次 ${relativeTime(s.lastSyncAt!, DateTime.now())}';
    return SizedBox(
      height: Tokens.bar,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(children: [
          Expanded(child: Text(s.error == null ? '$label · $when' : label, maxLines: 1, overflow: TextOverflow.ellipsis, style: muted?.copyWith(color: s.error == null ? null : Theme.of(context).colorScheme.error))),
          if (s.error != null) TextButton(onPressed: s.sync, child: const Text('重试')),
          if (s.error != null) IconButton(onPressed: s.clearError, icon: const Icon(Icons.close, size: 16), visualDensity: VisualDensity.compact),
          if (s.syncing) const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
        ]),
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.text, this.action, this.onAction, this.progress, this.busy = false});
  final String text;
  final String? action;
  final VoidCallback? onAction;
  final double? progress;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 8, 6),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(child: Text(text, style: Theme.of(context).textTheme.bodySmall)),
            if (action != null) TextButton(onPressed: onAction, child: Text(action!)),
          ]),
          if (busy) Padding(padding: const EdgeInsets.only(top: 4), child: LinearProgressIndicator(value: progress, minHeight: 2)),
        ]),
      ),
    );
  }
}

String _pct(Transfer t) {
  if (t.waiting) return '确认中';
  if (t.total <= 0) return '';
  final p = (100 * t.done / t.total).clamp(0, 99);
  return '${p.toStringAsFixed(0)}%';
}
