import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

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

  @override
  Widget build(BuildContext context) {
    final s = Scope.of(context);
    final n = _note(context);
    if (n == null) {
      return Scaffold(appBar: AppBar(), body: const Center(child: Text('这篇笔记已经不在了')));
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('笔记'),
        actions: [
          IconButton(
            tooltip: '添加文件',
            onPressed: () => _attach(context, s, n),
            icon: const Icon(Icons.attach_file),
          ),
          IconButton(
            tooltip: '删除',
            onPressed: () async {
              await s.remove(n);
              if (context.mounted) Navigator.of(context).pop();
            },
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            key: const Key('noteTitle'),
            controller: _title,
            style: Theme.of(context).textTheme.titleLarge,
            decoration: const InputDecoration(hintText: '标题', border: InputBorder.none),
            onChanged: (_) => _schedule(s, n),
          ),
          TextField(
            key: const Key('noteBody'),
            controller: _body,
            minLines: 8,
            maxLines: null,
            decoration: const InputDecoration(hintText: '开始写', border: InputBorder.none),
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
