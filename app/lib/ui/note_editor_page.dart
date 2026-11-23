import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../app_scope.dart';
import '../blocks/block_type.dart';
import '../models/block.dart';
import '../sync/sync_client.dart';
import 'block_card.dart';
import 'ds.dart';
import 'motion.dart';
import 'tokens.dart';

enum _NoteViewMode { edit, split, preview }

/// 零卡顿 Markdown 笔记编辑器（不透明页面卡片，杜绝与主页内容叠字重影）：
/// - 零卡顿输入：局部 ValueNotifier + 240ms 防抖预览，打字时零全页 rebuild；
/// - 打开即写：桌面宽屏默认左右实时分栏，窄屏一键切换编辑/预览；
/// - 内置常用 Markdown 格式工具栏、完成标记与优先级颜色快捷入口，支持 Ctrl+B / Ctrl+I / Ctrl+S；
/// - 保存时完整保留原 payload 中的完成状态、优先级颜色与便签坐标元数据。
class NoteEditorPage extends StatefulWidget {
  final String? blockId;
  final String? parentId;
  const NoteEditorPage({super.key, this.blockId, this.parentId});

  @override
  State<NoteEditorPage> createState() => _NoteEditorPageState();
}

class _NoteEditorPageState extends State<NoteEditorPage> {
  late final TextEditingController _title;
  late final TextEditingController _body;
  final _bodyFocus = FocusNode();
  final _dirtyNotifier = ValueNotifier<bool>(false);
  final _previewText = ValueNotifier<String>('');
  final _statsText = ValueNotifier<String>('0 字');

  String? _id;
  Timer? _saveDebounce;
  Timer? _previewDebounce;
  _NoteViewMode? _mode;

  SyncClient? _sync;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _id = widget.blockId;
    _title = TextEditingController();
    _body = TextEditingController();
  }

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
    _previewText.value = _body.text;
    _updateStats();
    _sync = AppScope.of(context).sync;
    _sync!.addListener(_onRemote);
  }

  void _updateStats() {
    final text = _body.text;
    final chars = text.replaceAll(RegExp(r'\s+'), '').length;
    final lines = text.isEmpty ? 0 : text.split('\n').length;
    _statsText.value = '$chars 字 · $lines 行';
  }

  /// 远程编辑到达且本地无未保存修改时，静默刷新内容。
  void _onRemote() {
    if (_id == null || !mounted) return;
    final b = _sync!.byId(_id!);
    if (b == null) return;
    if (!_dirtyNotifier.value) {
      final md = (b.payload['markdown'] ?? '') as String;
      if (md != _body.text) {
        final sel = _body.selection;
        _body.text = md;
        if (sel.end <= md.length) _body.selection = sel;
        _previewText.value = md;
        _updateStats();
      }
      if (b.title != _title.text) _title.text = b.title;
    }
    setState(() {});
  }

  void _changed() {
    if (!_dirtyNotifier.value) _dirtyNotifier.value = true;
    _updateStats();
    _previewDebounce?.cancel();
    _previewDebounce = Timer(const Duration(milliseconds: 240), () {
      if (mounted) _previewText.value = _body.text;
    });
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 600), _save);
  }

  Map<String, dynamic> _mergedPayload(SyncClient sync, String? id, String md) {
    final existing = id == null ? null : sync.byId(id)?.payload;
    if (existing == null) return {'markdown': md};
    return {...existing, 'markdown': md};
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
      sync.update(
        _id!,
        title: title.isEmpty ? '新笔记' : title,
        payload: _mergedPayload(sync, _id, _body.text),
      );
    }
    _dirtyNotifier.value = false;
  }

  void _wrapSelection(String prefix, [String suffix = '']) {
    final val = _body.value;
    final text = val.text;
    final sel = val.selection.isValid ? val.selection : TextSelection.collapsed(offset: text.length);
    final start = sel.start.clamp(0, text.length);
    final end = sel.end.clamp(0, text.length);
    final selected = text.substring(start, end);
    final replacement = '$prefix$selected$suffix';
    final nextText = text.replaceRange(start, end, replacement);
    final cursorStart = start + prefix.length;
    final cursorEnd = cursorStart + selected.length;
    _body.value = TextEditingValue(
      text: nextText,
      selection: selected.isEmpty
          ? TextSelection.collapsed(offset: cursorStart)
          : TextSelection(baseOffset: cursorStart, extentOffset: cursorEnd),
    );
    _bodyFocus.requestFocus();
    _changed();
  }

  void _prefixLine(String prefix) {
    final val = _body.value;
    final text = val.text;
    final pos = val.selection.isValid ? val.selection.start.clamp(0, text.length) : text.length;
    final lineStart = pos == 0 ? 0 : text.lastIndexOf('\n', pos - 1) + 1;
    final nextText = text.replaceRange(lineStart, lineStart, prefix);
    _body.value = TextEditingValue(
      text: nextText,
      selection: TextSelection.collapsed(offset: pos + prefix.length),
    );
    _bodyFocus.requestFocus();
    _changed();
  }

  @override
  void dispose() {
    _saveDebounce?.cancel();
    _previewDebounce?.cancel();
    _sync?.removeListener(_onRemote);
    if (_dirtyNotifier.value) {
      final sync = _sync, id = _id, title = _title.text, body = _body.text, parent = widget.parentId;
      Future.microtask(() => _saveDetached(sync, id, title, body, parent));
    }
    _title.dispose();
    _body.dispose();
    _bodyFocus.dispose();
    _dirtyNotifier.dispose();
    _previewText.dispose();
    _statsText.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final tt = Theme.of(context).textTheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final wide = MediaQuery.sizeOf(context).width >= 820;
    final activeMode = _mode ?? (wide ? _NoteViewMode.split : _NoteViewMode.edit);
    final currentBlock = _id == null ? null : _sync?.byId(_id!);
    final completed = currentBlock != null && isBlockCompleted(currentBlock);
    final stickyColor = currentBlock == null ? stickyColorOptions.last : stickyColorOf(currentBlock);

    Widget paneCard({required Widget child}) => Container(
          decoration: BoxDecoration(
            color: c.elevated,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: c.separator.withValues(alpha: dark ? 0.65 : 0.85)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: dark ? 0.22 : 0.05),
                blurRadius: 16,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          clipBehavior: Clip.antiAlias,
          child: child,
        );

    Widget fmtBtn(String tip, IconData icon, VoidCallback onTap) => Tooltip(
          message: tip,
          child: InkWell(
            borderRadius: BorderRadius.circular(AppRadius.s),
            onTap: onTap,
            child: SizedBox(
              width: 34,
              height: 32,
              child: Icon(icon, size: 16, color: c.text2),
            ),
          ),
        );

    final formatBar = Container(
      padding: const EdgeInsets.symmetric(horizontal: Gap.s, vertical: 3),
      decoration: BoxDecoration(
        color: c.fill.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: c.separator.withValues(alpha: 0.55)),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            fmtBtn('一级标题', CupertinoIcons.textformat_size, () => _prefixLine('# ')),
            fmtBtn('粗体 (Ctrl+B)', CupertinoIcons.bold, () => _wrapSelection('**', '**')),
            fmtBtn('斜体 (Ctrl+I)', CupertinoIcons.italic, () => _wrapSelection('*', '*')),
            fmtBtn('待办事项', CupertinoIcons.checkmark_square, () => _prefixLine('- [ ] ')),
            fmtBtn('无序列表', CupertinoIcons.list_bullet, () => _prefixLine('- ')),
            fmtBtn('引用', CupertinoIcons.quote_bubble, () => _prefixLine('> ')),
            fmtBtn('行内代码', CupertinoIcons.chevron_left_slash_chevron_right, () => _wrapSelection('`', '`')),
            fmtBtn('代码块', CupertinoIcons.doc_plaintext, () => _wrapSelection('\n```\n', '\n```\n')),
            fmtBtn('链接', CupertinoIcons.link, () => _wrapSelection('[', '](https://)')),
          ],
        ),
      ),
    );

    final editorPane = Padding(
      padding: const EdgeInsets.fromLTRB(Gap.xl, Gap.m, Gap.xl, Gap.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _title,
            onChanged: (_) => _changed(),
            style: tt.headlineSmall?.copyWith(fontWeight: FontWeight.w700, color: c.text),
            decoration: InputDecoration(
              hintText: '无标题笔记',
              hintStyle: tt.headlineSmall?.copyWith(fontWeight: FontWeight.w600, color: c.text3),
              filled: false,
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              contentPadding: const EdgeInsets.only(bottom: Gap.s),
            ),
          ),
          Divider(height: 1, color: c.separator.withValues(alpha: 0.6)),
          const SizedBox(height: Gap.m),
          Expanded(
            child: TextField(
              key: const Key('noteBody'),
              controller: _body,
              focusNode: _bodyFocus,
              onChanged: (_) => _changed(),
              maxLines: null,
              expands: true,
              textAlignVertical: TextAlignVertical.top,
              style: tt.bodyLarge?.copyWith(fontSize: 15.5, height: 1.7, color: c.text),
              decoration: InputDecoration(
                hintText: '直接开始写作… 支持 Markdown（# 标题、**粗体**、- [ ] 待办、`代码`）',
                hintStyle: tt.bodyMedium?.copyWith(color: c.text3),
                filled: false,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
              ),
            ),
          ),
        ],
      ),
    );

    final previewPane = ValueListenableBuilder<String>(
      valueListenable: _previewText,
      builder: (context, md, _) => Markdown(
        data: md.trim().isEmpty ? '*暂无正文内容*' : md,
        selectable: true,
        padding: const EdgeInsets.all(Gap.xl),
      ),
    );

    final Widget bodyContent;
    if (activeMode == _NoteViewMode.split && wide) {
      bodyContent = Row(
        key: const ValueKey('mode-split'),
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(Gap.l, Gap.s, Gap.s, Gap.l),
              child: paneCard(child: editorPane),
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(Gap.s, Gap.s, Gap.l, Gap.l),
              child: paneCard(child: previewPane),
            ),
          ),
        ],
      );
    } else if (activeMode == _NoteViewMode.preview) {
      bodyContent = Center(
        key: const ValueKey('mode-preview'),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 800),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(Gap.l, Gap.s, Gap.l, Gap.l),
            child: paneCard(child: previewPane),
          ),
        ),
      );
    } else {
      bodyContent = Center(
        key: const ValueKey('mode-edit'),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 800),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(Gap.l, Gap.s, Gap.l, Gap.l),
            child: paneCard(child: editorPane),
          ),
        ),
      );
    }

    Widget modeChip(_NoteViewMode m, String label) {
      final sel = activeMode == m;
      return GestureDetector(
        onTap: () {
          _previewText.value = _body.text;
          setState(() => _mode = m);
        },
        child: AnimatedContainer(
          duration: Motion.short2,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
          decoration: BoxDecoration(
            color: sel ? c.accent.withValues(alpha: 0.16) : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            label,
            style: tt.labelMedium?.copyWith(
              color: sel ? c.accent : c.text2,
              fontWeight: sel ? FontWeight.w600 : FontWeight.w500,
            ),
          ),
        ),
      );
    }

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyS, control: true): _save,
        const SingleActivator(LogicalKeyboardKey.keyS, meta: true): _save,
        const SingleActivator(LogicalKeyboardKey.keyB, control: true): () => _wrapSelection('**', '**'),
        const SingleActivator(LogicalKeyboardKey.keyI, control: true): () => _wrapSelection('*', '*'),
      },
      child: PopScope(
        onPopInvokedWithResult: (didPop, _) {
          if (_dirtyNotifier.value) _save();
        },
        child: Scaffold(
          backgroundColor: c.bg,
          appBar: AppBar(
            backgroundColor: c.bg,
            surfaceTintColor: Colors.transparent,
            titleSpacing: Gap.s,
            title: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(3),
                  decoration: BoxDecoration(
                    color: c.fill.withValues(alpha: 0.72),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: c.separator.withValues(alpha: 0.55)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      modeChip(_NoteViewMode.edit, '编辑'),
                      if (wide) modeChip(_NoteViewMode.split, '分栏'),
                      modeChip(_NoteViewMode.preview, '预览'),
                    ],
                  ),
                ),
                const SizedBox(width: Gap.m),
                if (wide && activeMode != _NoteViewMode.preview)
                  Expanded(child: Align(alignment: Alignment.centerLeft, child: formatBar)),
              ],
            ),
            actions: [
              if (currentBlock != null) ...[
                Builder(
                  builder: (dotCtx) => Tooltip(
                    message: stickyColor.tag.isEmpty ? '设置优先级与颜色' : '${stickyColor.label}（点击切换）',
                    child: IconButton(
                      onPressed: () {
                        Offset? anchor;
                        final box = dotCtx.findRenderObject() as RenderBox?;
                        if (box != null) anchor = box.localToGlobal(Offset(box.size.width / 2, box.size.height));
                        showStickyColorPicker(context, currentBlock, anchor: anchor);
                      },
                      icon: Container(
                        width: 14,
                        height: 14,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: stickyColor.color ?? c.text3.withValues(alpha: 0.25),
                          border: Border.all(color: stickyColor.color ?? c.text3, width: 1.5),
                        ),
                      ),
                    ),
                  ),
                ),
                Tooltip(
                  message: completed ? '取消完成' : '标为已完成',
                  child: IconButton(
                    key: const Key('noteCompleteToggle'),
                    onPressed: () {
                      if (_dirtyNotifier.value) _save();
                      final latest = _sync?.byId(currentBlock.id) ?? currentBlock;
                      setBlockCompleted(_sync!, latest, !completed);
                    },
                    icon: Icon(
                      completed ? CupertinoIcons.checkmark_circle_fill : CupertinoIcons.circle,
                      size: Sizes.iconMd,
                      color: completed ? c.success : c.text2,
                    ),
                  ),
                ),
              ],
              Center(
                child: ValueListenableBuilder<String>(
                  valueListenable: _statsText,
                  builder: (context, s, _) => Padding(
                    padding: const EdgeInsets.only(right: Gap.s),
                    child: Text(s, style: tt.bodySmall?.copyWith(color: c.text3)),
                  ),
                ),
              ),
              ValueListenableBuilder<bool>(
                valueListenable: _dirtyNotifier,
                builder: (context, dirty, _) => Tooltip(
                  message: dirty ? '正在同步保存…' : '已自动保存 (Ctrl+S)',
                  child: IconButton(
                    onPressed: _save,
                    icon: dirty
                        ? const SizedBox.square(
                            key: ValueKey('saving'),
                            dimension: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Icon(
                            CupertinoIcons.checkmark_alt_circle,
                            key: const ValueKey('saved'),
                            size: Sizes.iconMd,
                            color: c.accent,
                          ),
                  ),
                ),
              ),
              const SizedBox(width: Gap.xs),
            ],
          ),
          body: Column(
            children: [
              if (!wide && activeMode != _NoteViewMode.preview)
                Padding(
                  padding: const EdgeInsets.fromLTRB(Gap.l, Gap.xs, Gap.l, Gap.xs),
                  child: formatBar,
                ),
              Expanded(child: MotionSwitch(child: bodyContent)),
            ],
          ),
        ),
      ),
    );
  }
}

void _saveDetached(SyncClient? sync, String? id, String title, String body, String? parentId) {
  if (sync == null) return;
  final t = title.trim().isEmpty ? body.trim().split('\n').first.replaceAll('#', '').trim() : title.trim();
  if (id == null) {
    if (body.trim().isEmpty && title.trim().isEmpty) return;
    sync.create(kind: BlockKind.note, title: t.isEmpty ? '新笔记' : t, payload: {'markdown': body}, parentId: parentId);
  } else {
    final existing = sync.byId(id)?.payload;
    final payload = existing == null ? {'markdown': body} : {...existing, 'markdown': body};
    sync.update(id, title: t.isEmpty ? '新笔记' : t, payload: payload);
  }
}
