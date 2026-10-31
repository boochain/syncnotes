import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
      body: ListView(
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
              IconButton(tooltip: '链接到笔记', onPressed: () => _wrap(s, n, '[[', ']]'), icon: const Icon(Icons.link)),
              IconButton(tooltip: '添加文件', onPressed: () => _attach(context, s, n), icon: const Icon(Icons.attach_file)),
            ]),
          ],
          TextField(
            key: const Key('noteTitle'),
            controller: _title,
            style: Theme.of(context).textTheme.titleLarge,
            decoration: const InputDecoration(hintText: '标题', border: InputBorder.none),
            onChanged: (_) => _schedule(s, n),
          ),
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
            )
          else
            TextField(
              key: const Key('noteBody'),
              controller: _body,
              minLines: 8,
              maxLines: null,
              decoration: const InputDecoration(hintText: '开始写。用 [[标题]] 链接另一篇笔记。', border: InputBorder.none),
              onChanged: (_) => _schedule(s, n),
            ),
          for (final f in n.files)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.insert_drive_file_outlined),
              title: Text(f.name),
              subtitle: Text(_size(f.size)),
              onTap: () => _save(context, s, f),
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
    );
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
