import 'dart:async';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'device.dart';
import 'draw_page.dart';
import 'library.dart';
import 'markdown_view.dart';
import 'scope.dart';
import 'session.dart';

class EditorPage extends StatefulWidget {
  const EditorPage({super.key, required this.noteId});
  final String noteId;

  @override
  State<EditorPage> createState() => EditorPageState();
}

class EditorPageState extends State<EditorPage> {
  final _title = TextEditingController();
  final _body = TextEditingController();
  Timer? _timer;
  var _ready = false;
  var _preview = false;
  var _focus = false;
  var _finding = false;
  var _dropping = false;
  List<SlashCommand> _slash = const [];
  final _find = TextEditingController();
  final _replace = TextEditingController();

  Note? _note(BuildContext context) {
    for (final n in Scope.of(context).notes) {
      if (n.id == widget.noteId) return n;
    }
    return null;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_ready) return;
    final n = _note(context);
    if (n == null) return;
    _ready = true;
    _title.text = n.title;
    _body.text = n.body;
  }

  @override
  void dispose() {
    _timer?.cancel();
    _title.dispose();
    _body.dispose();
    _find.dispose();
    _replace.dispose();
    super.dispose();
  }

  void _schedule(Session s, Note n) {
    s.edit(n, title: _title.text, body: _body.text);
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 400), () => s.push(n));
  }

  void _apply(Session s, Note n, String next, int cursor) {
    _body.value = TextEditingValue(text: next, selection: TextSelection.collapsed(offset: cursor.clamp(0, next.length)));
    _schedule(s, n);
  }

  void _wrap(Session s, Note n, String left, String right) {
    final v = _body.value;
    final start = v.selection.start < 0 ? _body.text.length : v.selection.start;
    final end = v.selection.end < 0 ? _body.text.length : v.selection.end;
    final next = wrapRange(_body.text, start, end, left, right);
    _apply(s, n, next, (start <= end ? end : start) + left.length);
  }

  void _onBody(Session s, Note n) {
    _schedule(s, n);
    final text = _body.text;
    final cursor = _body.selection.start < 0 ? text.length : _body.selection.start;
    final start = text.lastIndexOf('\n', cursor <= 0 ? 0 : cursor - 1) + 1;
    var end = text.indexOf('\n', cursor);
    if (end < 0) end = text.length;
    final line = text.substring(start, end);
    final matches = matchSlash(line);
    setState(() => _slash = matches);
  }

  void _runSlash(Session s, Note n, SlashCommand command) {
    if (command.name == '删除线') {
      _wrap(s, n, '~~', '~~');
      setState(() => _slash = const []);
      return;
    }
    final insert = command.insert == '__DATE__' ? DateTime.now().toIso8601String().substring(0, 10) : command.insert;
    final cursor = _body.selection.start < 0 ? _body.text.length : _body.selection.start;
    final next = replaceCurrentLine(_body.text, cursor, insert);
    _apply(s, n, next, cursor);
    setState(() => _slash = const []);
  }

  void _findNext() {
    final at = nextMatch(_body.text, _find.text, _body.selection.end < 0 ? 0 : _body.selection.end);
    if (at < 0) return;
    _body.selection = TextSelection(baseOffset: at, extentOffset: at + _find.text.trim().length);
    setState(() => _preview = false);
  }

  void _prefix(Session s, Note n, String prefix) {
    final v = _body.value;
    final start = v.selection.start < 0 ? _body.text.length : v.selection.start;
    final end = v.selection.end < 0 ? start : v.selection.end;
    _apply(s, n, prefixLines(_body.text, start, end, prefix), start + prefix.length);
  }

  Future<void> _tags(Session s, Note n) async {
    final box = TextEditingController(text: n.tags.join(' '));
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('标签'),
        content: TextField(controller: box, decoration: const InputDecoration(hintText: '用空格分开')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('保存')),
        ],
      ),
    );
    if (ok == true) {
      n.tags
        ..clear()
        ..addAll(box.text.split(RegExp(r'\s+')).where((t) => t.isNotEmpty));
      s.touch(n);
      if (mounted) setState(() {});
    }
    box.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = Scope.of(context);
    final n = _note(context);
    if (n == null) return Scaffold(appBar: AppBar(), body: const Center(child: Text('这篇笔记已经不在了')));
    final folders = folderNotes(s.notes);
    final links = backlinksOf(s.notes, n);
    final words = wordCount('${_title.text}\n${_body.text}');
    return Scaffold(
      appBar: AppBar(
        title: Text(_focus ? '专注' : '$words 字'),
        actions: [
          IconButton(tooltip: n.pinned ? '取消置顶' : '置顶', onPressed: () { n.pinned = !n.pinned; s.touch(n); }, icon: Icon(n.pinned ? Icons.push_pin : Icons.push_pin_outlined)),
          IconButton(tooltip: _preview ? '编辑' : '预览', onPressed: () => setState(() => _preview = !_preview), icon: Icon(_preview ? Icons.edit : Icons.visibility)),
          IconButton(tooltip: _focus ? '退出专注' : '专注模式', onPressed: () => setState(() => _focus = !_focus), icon: const Icon(Icons.fullscreen)),
          PopupMenuButton<String>(
            onSelected: (v) async {
              if (v == 'copy') {
                await Clipboard.setData(ClipboardData(text: exportMarkdown(n)));
                if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已复制 Markdown')));
              }
              if (v == 'dup') {
                final copy = s.duplicate(n);
                if (context.mounted) Navigator.of(context).push(MaterialPageRoute(builder: (_) => EditorPage(noteId: copy.id)));
              }
              if (v == 'trash') {
                s.trashNote(n);
                if (context.mounted) Navigator.of(context).pop();
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'copy', child: Text('复制为 Markdown')),
              PopupMenuItem(value: 'dup', child: Text('复制这篇笔记')),
              PopupMenuItem(value: 'trash', child: Text('移到回收站')),
            ],
          ),
        ],
      ),
      body: DropTarget(
        onDragEntered: (_) => setState(() => _dropping = true),
        onDragExited: (_) => setState(() => _dropping = false),
        onDragDone: (detail) async {
          setState(() => _dropping = false);
          for (final file in detail.files) {
            final path = file.path;
            if (path.isEmpty) continue;
            final name = file.name.isEmpty ? '文件' : file.name;
            final image = RegExp(r'\.(png|jpe?g|gif|webp|bmp)$', caseSensitive: false).hasMatch(name);
            final len = await file.length();
            await _putFile(s, n, name, () => File(path).openRead(), len, image: image);
          }
          if (detail.files.isEmpty && context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('没接到文件。请从文件夹里拖一个文件过来。')));
          }
        },
        child: Stack(children: [
          ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (!_focus) ...[
            Wrap(spacing: 8, children: [
              ActionChip(label: Text(n.tags.isEmpty ? '加标签' : n.tags.map((t) => '#$t').join(' ')), onPressed: () => _tags(s, n)),
              DropdownButton<String?>(
                value: folders.any((f) => f.id == n.folderId) ? n.folderId : null,
                hint: const Text('文件夹'),
                items: [
                  const DropdownMenuItem(value: null, child: Text('不放入文件夹')),
                  for (final f in folders) DropdownMenuItem(value: f.id, child: Text(f.heading)),
                ],
                onChanged: (id) {
                  n.folderId = id;
                  s.touch(n);
                },
              ),
            ]),
            Wrap(children: [
              IconButton(tooltip: '粗体', onPressed: () => _wrap(s, n, '**', '**'), icon: const Icon(Icons.format_bold)),
              IconButton(tooltip: '斜体', onPressed: () => _wrap(s, n, '*', '*'), icon: const Icon(Icons.format_italic)),
              IconButton(tooltip: '标题', onPressed: () => _prefix(s, n, '## '), icon: const Icon(Icons.title)),
              IconButton(tooltip: '列表', onPressed: () => _prefix(s, n, '- '), icon: const Icon(Icons.format_list_bulleted)),
              IconButton(tooltip: '待办', onPressed: () => _prefix(s, n, '- [ ] '), icon: const Icon(Icons.check_box_outlined)),
              IconButton(tooltip: '引用', onPressed: () => _prefix(s, n, '> '), icon: const Icon(Icons.format_quote)),
              IconButton(tooltip: '代码', onPressed: () => _wrap(s, n, '`', '`'), icon: const Icon(Icons.code)),
              IconButton(tooltip: '删除线', onPressed: () => _wrap(s, n, '~~', '~~'), icon: const Icon(Icons.format_strikethrough)),
              IconButton(tooltip: '编号', onPressed: () => _prefix(s, n, '1. '), icon: const Icon(Icons.format_list_numbered)),
              IconButton(tooltip: '分隔线', onPressed: () => _prefix(s, n, '---\n'), icon: const Icon(Icons.horizontal_rule)),
              IconButton(tooltip: '链接到笔记', onPressed: () => _wrap(s, n, '[[', ']]'), icon: const Icon(Icons.link)),
              IconButton(tooltip: '在这篇里查找', onPressed: () => setState(() => _finding = !_finding), icon: const Icon(Icons.search)),
              IconButton(tooltip: '添加文件', onPressed: () => _attach(context, s, n), icon: const Icon(Icons.attach_file)),
            ]),
            Wrap(spacing: 6, children: [
              ActionChip(label: const Text('表格'), onPressed: () => _insert(s, n, markdownTable())),
              ActionChip(label: const Text('粘贴图片'), onPressed: () => _pasteImage(context, s, n)),
              ActionChip(label: const Text('图片'), onPressed: () => _image(context, s, n)),
              ActionChip(label: const Text('手写'), onPressed: () => _ink(context, s, n)),
              ActionChip(label: const Text('扫描'), onPressed: () => _scan(context, s, n)),
              ActionChip(label: const Text('语音'), onPressed: () => _voice(context, s, n)),
              ActionChip(label: const Text('提醒'), onPressed: () => _remind(context, s, n)),
              ActionChip(label: const Text('历史'), onPressed: () => _history(context, s, n)),
              ActionChip(label: const Text('分享给别人'), onPressed: () => _share(context, s, n)),
              for (final e in noteColors.entries)
                if (e.key.isNotEmpty)
                  ChoiceChip(
                    label: Text(e.value),
                    selected: n.color == e.key,
                    onSelected: (_) {
                      n.color = n.color == e.key ? '' : e.key;
                      s.touch(n);
                    },
                  ),
            ]),
          ],
          TextField(
            key: const Key('noteTitle'),
            controller: _title,
            style: Theme.of(context).textTheme.titleLarge,
            decoration: const InputDecoration(hintText: '标题', border: InputBorder.none),
            onChanged: (_) => _schedule(s, n),
          ),
          if (_finding) ...[
            Row(children: [
              Expanded(child: TextField(controller: _find, decoration: const InputDecoration(hintText: '查找'), onSubmitted: (_) => _findNext())),
              TextButton(onPressed: _findNext, child: const Text('下一个')),
            ]),
            Row(children: [
              Expanded(child: TextField(controller: _replace, decoration: const InputDecoration(hintText: '替换成'))),
              TextButton(onPressed: () => _swap(s, n, all: false), child: const Text('替换')),
              TextButton(onPressed: () => _swap(s, n, all: true), child: const Text('全部')),
            ]),
          ],
          if (_slash.isNotEmpty)
            Card(
              child: Column(children: [
                for (final c in _slash)
                  ListTile(dense: true, title: Text('/${c.name}'), subtitle: Text(c.hint), onTap: () => _runSlash(s, n, c)),
              ]),
            ),
          if (!_focus && headingsOf(_body.text).isNotEmpty)
            Wrap(spacing: 6, children: [
              for (final h in headingsOf(_body.text))
                ActionChip(label: Text(h.text), onPressed: () {
                  final lines = _body.text.split('\n');
                  var offset = 0;
                  for (var i = 0; i < h.line && i < lines.length; i++) {
                    offset += lines[i].length + 1;
                  }
                  _body.selection = TextSelection.collapsed(offset: offset);
                  setState(() => _preview = false);
                }),
            ]),
          if (_preview)
            MarkdownBody(
              text: _body.text,
              onWiki: (title) {
                final hit = noteByTitle(s.notes, title);
                final opened = hit ?? s.create(title: title);
                Navigator.of(context).push(MaterialPageRoute(builder: (_) => EditorPage(noteId: opened.id)));
              },
              onToggleTask: (line) {
                final next = toggleTaskLine(_body.text, line);
                _body.text = next;
                _schedule(s, n);
                setState(() {});
              },
              onFile: (id) {
                final hit = n.files.where((f) => f.id == id);
                if (hit.isNotEmpty) _save(context, s, hit.first);
              },
            )
          else
            TextField(
              key: const Key('noteBody'),
              controller: _body,
              minLines: 8,
              maxLines: null,
              decoration: const InputDecoration(hintText: '开始写。输入 / 可以选择待办、标题、日期。用 [[标题]] 链接另一篇笔记。', border: InputBorder.none),
              onChanged: (_) => _onBody(s, n),
            ),
          for (final f in n.files)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.insert_drive_file_outlined),
              title: Text(f.name),
              subtitle: Text(_size(f.size)),
              trailing: IconButton(
                tooltip: '从笔记里去掉',
                onPressed: () async {
                  final ok = await showDialog<bool>(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: const Text('去掉附件'),
                      content: Text('「${f.name}」会从这篇笔记拿掉。'),
                      actions: [
                        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
                        FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('去掉')),
                      ],
                    ),
                  );
                  if (ok == true) s.removeFile(n, f.id);
                },
                icon: const Icon(Icons.close),
              ),
              onTap: () => _save(context, s, f),
            ),
          if (!_focus) ...[
            const Divider(),
            Text('评论', style: Theme.of(context).textTheme.titleSmall),
            for (final c in n.comments) ListTile(contentPadding: EdgeInsets.zero, title: Text(c.text), subtitle: Text(relativeTime(c.at, DateTime.now()))),
            TextField(
              decoration: const InputDecoration(hintText: '写一条评论，只在你的设备之间同步'),
              onSubmitted: (v) {
                s.addComment(n, v);
                setState(() {});
              },
            ),
          ],
          if (!_focus)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Text('创建于 ${relativeTime(n.createdAt, DateTime.now())} · 改于 ${relativeTime(n.updatedAt, DateTime.now())}', style: Theme.of(context).textTheme.bodySmall),
            ),
          if (!_focus && links.isNotEmpty) ...[
            const Divider(),
            Text('反向链接', style: Theme.of(context).textTheme.titleSmall),
            for (final other in links)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(other.heading),
                onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => EditorPage(noteId: other.id))),
              ),
          ],
        ],
          ),
          if (_dropping)
            const Positioned.fill(
              child: ColoredBox(
                color: Color(0xAA3D5AFE),
                child: Center(child: Text('松开，文件就放进这篇笔记', style: TextStyle(color: Colors.white, fontSize: 18))),
              ),
            ),
        ]),
      ),
    );
  }

  void _insert(Session s, Note n, String chunk) {
    final cursor = _body.selection.start < 0 ? _body.text.length : _body.selection.start;
    final next = _body.text.replaceRange(cursor, cursor, chunk);
    _apply(s, n, next, cursor + chunk.length);
  }

  void _swap(Session s, Note n, {required bool all}) {
    final from = _body.selection.end < 0 ? 0 : _body.selection.end;
    final result = replaceMatches(_body.text, _find.text, _replace.text, all: all, from: from);
    if (result.count == 0) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('没有找到')));
      return;
    }
    _apply(s, n, result.text, 0);
  }

  Future<void> _putFile(Session s, Note n, String name, Stream<List<int>> Function() open, int size, {bool image = false}) async {
    final att = await s.attach(n, name, open, size);
    if (att != null && image) _insert(s, n, '![${att.name}](snfile:${att.id})\n');
    if (mounted) setState(() {});
  }

  Future<void> _pasteImage(BuildContext context, Session s, Note n) async {
    final bytes = await Device.clipboardImage();
    if (!context.mounted) return;
    if (bytes == null || bytes.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('剪贴板里没有图片。可以先复制一张图，或把文件拖进这篇笔记。')));
      return;
    }
    final name = bytes.length > 2 && bytes[0] == 0x89 ? '粘贴.png' : '粘贴.bmp';
    await _putFile(s, n, name, () => Stream.value(bytes), bytes.length, image: true);
  }

  Future<void> _image(BuildContext context, Session s, Note n) async {
    final picked = await FilePicker.pickFiles(type: FileType.image);
    if (picked.isEmpty) return;
    final f = picked.first;
    final path = f.path;
    final len = f.lengthSync() ?? await f.length() ?? 0;
    await _putFile(s, n, f.name, () => path != null ? File(path).openRead() : f.readAsByteStream(), len, image: true);
  }

  Future<void> _ink(BuildContext context, Session s, Note n) async {
    final bytes = await Navigator.of(context).push<Uint8List>(MaterialPageRoute(builder: (_) => const DrawPage()));
    if (bytes == null) return;
    await _putFile(s, n, '手写.png', () => Stream.value(bytes), bytes.length, image: true);
  }

  Future<void> _scan(BuildContext context, Session s, Note n) async {
    if (Platform.isAndroid) {
      try {
        final shot = await Device.capture();
        final path = shot?['path'] as String?;
        if (path != null) {
          final file = File(path);
          await _putFile(s, n, '${shot?['name'] ?? '扫描.jpg'}', file.openRead, await file.length(), image: true);
          return;
        }
      } catch (e) {
        if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('拍照没成功：$e')));
      }
    }
    if (!context.mounted) return;
    await _image(context, s, n);
  }

  Future<void> _voice(BuildContext context, Session s, Note n) async {
    if (!Platform.isAndroid) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('语音转文字用的是手机系统识别。这台电脑请用手写，或直接打字。')));
      }
      return;
    }
    try {
      final text = await Device.listen();
      if (text == null || text.trim().isEmpty) return;
      _insert(s, n, text.trim());
    } catch (e) {
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('没听清：$e')));
    }
  }

  Future<void> _remind(BuildContext context, Session s, Note n) async {
    final date = await showDatePicker(context: context, firstDate: DateTime.now().subtract(const Duration(days: 1)), lastDate: DateTime.now().add(const Duration(days: 3650)), initialDate: DateTime.now());
    if (date == null || !context.mounted) return;
    final time = await showTimePicker(context: context, initialTime: TimeOfDay.now());
    if (time == null) return;
    final when = DateTime(date.year, date.month, date.day, time.hour, time.minute);
    n.remindAt = when.millisecondsSinceEpoch;
    s.touch(n);
    await Device.scheduleReminder(when.millisecondsSinceEpoch, n.heading, n.body.split('\n').first, n.id.hashCode);
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('会在 ${when.month}月${when.day}日 ${time.format(context)} 提醒。手机关着也会通知。')));
  }

  Future<void> _history(BuildContext context, Session s, Note n) async {
    if (n.history.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('还没有更早的版本。改过一会儿之后会留下。')));
      return;
    }
    final picked = await showModalBottomSheet<Revision>(
      context: context,
      builder: (context) => SafeArea(
        child: ListView(children: [
          for (final h in n.history.reversed)
            ListTile(
              title: Text(h.title.isEmpty ? '无标题' : h.title),
              subtitle: Text(relativeTime(h.at, DateTime.now())),
              onTap: () => Navigator.pop(context, h),
            ),
        ]),
      ),
    );
    if (picked == null) return;
    s.restoreRevision(n, picked);
    _title.text = n.title;
    _body.text = n.body;
    setState(() {});
  }

  Future<void> _share(BuildContext context, Session s, Note n) async {
    final pass = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('分享给别人'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('对方需要这台服务器的地址、分享编号，以及你现在设的分享密码。不要用登录密码。对方拿到的是当时的一份副本。'),
          const SizedBox(height: 8),
          TextField(controller: pass, obscureText: true, decoration: const InputDecoration(labelText: '分享密码')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('生成')),
        ],
      ),
    );
    final secret = pass.text;
    pass.dispose();
    if (ok != true || !context.mounted) return;
    try {
      final id = await s.shareNote(n, secret);
      if (!context.mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('把这两样告诉对方'),
          content: SelectableText('分享编号：$id\n服务器：${s.server}'),
          actions: [
            TextButton(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: '服务器：${s.server}\n分享编号：$id'));
                Navigator.pop(context);
              },
              child: const Text('复制'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _attach(BuildContext context, Session s, Note n) async {
    final picked = await FilePicker.pickFiles();
    if (picked.isEmpty) return;
    final f = picked.first;
    final len = f.lengthSync() ?? await f.length() ?? 0;
    final path = f.path;
    await s.attach(n, f.name, () => path != null ? File(path).openRead() : f.readAsByteStream(), len);
    if (mounted) setState(() {});
  }

  Future<void> _save(BuildContext context, Session s, Attachment f) async {
    try {
      final file = await s.download(f);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('已保存到 ${file.path}')));
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  String _size(int n) {
    if (n < 1024) return '$n B';
    if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(1)} KB';
    return '${(n / 1024 / 1024).toStringAsFixed(1)} MB';
  }
}
