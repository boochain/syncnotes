import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../app_scope.dart';
import '../blocks/block_type.dart';
import '../models/block.dart';
import '../sync/sync_client.dart';

/// Markdown 笔记编辑器：编辑 / 预览，自动保存（防抖）并实时同步。
class NoteEditorPage extends StatefulWidget {
  final String? blockId;
  final String? parentId;
  const NoteEditorPage({super.key, this.blockId, this.parentId});

  @override
  State<NoteEditorPage> createState() => _NoteEditorPageState();
}

class _NoteEditorPageState extends State<NoteEditorPage> with SingleTickerProviderStateMixin {
  late final TextEditingController _title;
  late final TextEditingController _body;
  late final TabController _tabs;
  String? _id;
  Timer? _debounce;
  bool _dirty = false;

  @override
  void initState() {
    super.initState();
    _id = widget.blockId;
    _title = TextEditingController();
    _body = TextEditingController();
    _tabs = TabController(length: 2, vsync: this, initialIndex: widget.blockId == null ? 0 : 1);
  }

  SyncClient? _sync;
  bool _loaded = false;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loaded) return;
    _loaded = true;
    if (_id != null) {
      final b = AppScope.of(context).sync.byId(_id!);
      _title.text = b?.title ?? '';
      _body.text = b == null ? '' : (b.payload['markdown'] ?? '') as String;
    }
    _sync = AppScope.of(context).sync;
    _sync!.addListener(_onRemote);
  }

  /// 远程编辑到达且本地无未保存修改时，刷新内容。
  void _onRemote() {
    if (_id == null || _dirty || !mounted) return;
    final b = _sync!.byId(_id!);
    if (b == null) return;
    final md = (b.payload['markdown'] ?? '') as String;
    if (md != _body.text) {
      final sel = _body.selection;
      _body.text = md;
      if (sel.end <= md.length) _body.selection = sel;
    }
    if (b.title != _title.text) _title.text = b.title;
    setState(() {});
  }

  void _changed() {
    _dirty = true;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 600), _save);
    setState(() {});
  }

  void _save() {
    final sync = _sync;
    if (sync == null) return;
    final title = _title.text.trim().isEmpty
        ? (_body.text.trim().split('\n').first.replaceAll('#', '').trim())
        : _title.text.trim();
    if (_id == null) {
      if (_body.text.trim().isEmpty && _title.text.trim().isEmpty) return;
      _id = sync
          .create(
            kind: BlockKind.note,
            title: title.isEmpty ? '新笔记' : title,
            payload: {'markdown': _body.text},
            parentId: widget.parentId,
            viewedMode: mounted ? defaultViewedMode(context) : ViewedMode.perDevice,
          )
          .id;
    } else {
      sync.update(_id!, title: title.isEmpty ? '新笔记' : title, payload: {'markdown': _body.text});
    }
    _dirty = false;
  }

  @override
  void dispose() {
    _debounce?.cancel();
    if (_dirty) _save();
    _sync?.removeListener(_onRemote);
    _title.dispose();
    _body.dispose();
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      onPopInvokedWithResult: (didPop, _) {
        if (_dirty) _save();
      },
      child: Scaffold(
        appBar: AppBar(
          title: TextField(
            controller: _title,
            onChanged: (_) => _changed(),
            style: Theme.of(context).textTheme.titleLarge,
            decoration: const InputDecoration(hintText: '标题', border: InputBorder.none),
          ),
          actions: [
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              child: _dirty
                  ? const Padding(
                      key: ValueKey('saving'),
                      padding: EdgeInsets.all(16),
                      child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)))
                  : const Padding(
                      key: ValueKey('saved'), padding: EdgeInsets.all(16), child: Icon(Icons.cloud_done_outlined)),
            ),
          ],
          bottom: TabBar(controller: _tabs, tabs: const [Tab(text: '编辑'), Tab(text: '预览')]),
        ),
        body: TabBarView(controller: _tabs, children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              key: const Key('noteBody'),
              controller: _body,
              onChanged: (_) => _changed(),
              maxLines: null,
              expands: true,
              textAlignVertical: TextAlignVertical.top,
              style: const TextStyle(fontFamily: 'monospace', height: 1.5),
              decoration: const InputDecoration(
                  hintText: '支持 Markdown：# 标题、**粗体**、- 列表、`代码`…', border: InputBorder.none),
            ),
          ),
          Markdown(data: _body.text, selectable: true, padding: const EdgeInsets.all(16)),
        ]),
      ),
    );
  }
}
