import 'dart:async';
import '../ui/tokens.dart';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_highlight/flutter_highlight.dart';
import 'package:flutter_highlight/themes/atom-one-dark.dart';
import 'package:flutter_highlight/themes/github.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_scope.dart';
import '../models/block.dart';
import '../ui/ds.dart';
import '../ui/glass.dart';
import 'commands.dart';
import 'doc.dart';
import 'inline_md.dart';
import 'page_nav.dart';

/// 页面中的一行（一个内容块或子页面链接）。
class BlockRow extends StatefulWidget {
  final DocController doc;
  final DocRow row;
  final int index;
  const BlockRow({super.key, required this.doc, required this.row, required this.index});

  @override
  State<BlockRow> createState() => BlockRowState();
}

class BlockRowState extends State<BlockRow> {
  late final InlineMarkdownController _ctrl = InlineMarkdownController(text: docText(widget.row.block));
  final FocusNode _focus = FocusNode();
  final OverlayPortalController _slash = OverlayPortalController();
  final LayerLink _link = LayerLink();
  Timer? _debounce;
  bool _hover = false;
  bool _syncingFromRemote = false;
  int _slashIndex = 0;
  String _slashQuery = '';
  int _slashStart = -1;

  Block get block => widget.row.block;
  DocType get type => widget.row.type;
  DocController get doc => widget.doc;

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocusChange);
    doc.focusRequest.addListener(_onFocusRequest);
    WidgetsBinding.instance.addPostFrameCallback((_) => _onFocusRequest());
  }

  @override
  void didUpdateWidget(covariant BlockRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    _pullModel();
  }

  /// 用模型中的文本刷新输入框（远程更新、合并、撤销）。
  /// 仅在本行没有未保存的输入、且不在输入法组字中时覆盖，光标位置尽量保持。
  void _pullModel() {
    final cur = doc.sync.byId(block.id) ?? block;
    final remote = docText(cur);
    if (_debounce != null || remote == _ctrl.text || _ctrl.value.composing.isValid) return;
    final sel = _ctrl.selection;
    _syncingFromRemote = true;
    _ctrl.value = TextEditingValue(
      text: remote,
      selection: sel.isValid
          ? TextSelection.collapsed(offset: sel.baseOffset.clamp(0, remote.length))
          : TextSelection.collapsed(offset: remote.length),
    );
    _syncingFromRemote = false;
  }

  @override
  void dispose() {
    _flush();
    doc.focusRequest.removeListener(_onFocusRequest);
    _focus.dispose();
    _ctrl.dispose();
    super.dispose();
  }

  void _onFocusChange() {
    _ctrl.reveal = _focus.hasFocus;
    if (_focus.hasFocus) {
      doc.focusedId.value = block.id;
    } else {
      _flush();
      if (doc.focusedId.value == block.id) doc.focusedId.value = null;
      if (_slash.isShowing) _slash.hide();
    }
    if (mounted) setState(() {});
  }

  void _onFocusRequest() {
    final r = doc.focusRequest.value;
    if (r == null || r.id != block.id || !mounted) return;
    doc.focusRequest.value = null;
    if (!isTextual(type)) {
      _focus.requestFocus();
      return;
    }
    _focus.requestFocus();
    _pullModel();
    final len = _ctrl.text.length;
    if (r.offset == -2) return; // 保持原光标
    final off = r.offset < 0 || r.offset > len ? len : r.offset;
    _ctrl.selection = TextSelection.collapsed(offset: off);
  }

  void _flush() {
    if (_debounce != null) {
      _debounce!.cancel();
      _debounce = null;
      doc.setText(block.id, _ctrl.text);
    }
  }

  // ------------------------------------------------------------- text input

  void _onChanged(String text) {
    if (_syncingFromRemote) return;
    // 软键盘回车（移动端）：文本中出现换行即拆分
    if (type != DocType.code && text.contains('\n')) {
      final i = text.indexOf('\n');
      _debounce?.cancel();
      _debounce = null;
      final before = text.substring(0, i);
      final after = text.substring(i + 1).replaceAll('\n', '');
      _ctrl.text = before;
      doc.split(block.id, before, after);
      return;
    }
    // Markdown 快捷方式（仅段落）
    if (type == DocType.paragraph) {
      final sc = detectShortcut(text);
      if (sc != null) {
        _debounce?.cancel();
        _debounce = null;
        final (name, rest) = sc;
        _ctrl.text = rest;
        if (name == 'todo_checked') {
          doc.setType(block.id, DocType.todo, text: rest);
          doc.setPayload(block.id, {'checked': true});
        } else {
          doc.setType(block.id, DocType.values.byName(name), text: rest);
        }
        return;
      }
    }
    _updateSlash(text);
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () {
      _debounce = null;
      doc.setText(block.id, _ctrl.text);
    });
  }

  void _updateSlash(String text) {
    final caret = _ctrl.selection.baseOffset;
    if (caret < 0 || type == DocType.code) return;
    final before = text.substring(0, caret.clamp(0, text.length));
    final i = before.lastIndexOf('/');
    final valid = i >= 0 && (i == 0 || before[i - 1] == ' ') && !before.substring(i).contains(' ');
    if (valid && filterCommands(before.substring(i + 1)).isNotEmpty) {
      setState(() {
        _slashStart = i;
        _slashQuery = before.substring(i + 1);
        _slashIndex = 0;
      });
      if (!_slash.isShowing) _slash.show();
    } else if (_slash.isShowing) {
      _slash.hide();
      _slashStart = -1;
    }
  }

  Future<void> _applyCommand(SlashCommand c) async {
    _slash.hide();
    // 删除 "/查询" 文本
    final t = _ctrl.text;
    final end = (_slashStart + 1 + _slashQuery.length).clamp(0, t.length);
    final rest = _slashStart >= 0 ? t.replaceRange(_slashStart, end, '') : t;
    _slashStart = -1;
    _debounce?.cancel();
    _debounce = null;
    _ctrl.text = rest;
    if (c.special == 'page') {
      doc.setText(block.id, rest);
      final id = doc.createSubpage(block);
      if (rest.isEmpty) doc.remove(block.id, focusPrevious: false);
      if (mounted) openPage(context, id);
      return;
    }
    final target = c.type!;
    if (rest.isEmpty || !isTextual(target)) {
      doc.setType(block.id, target, text: isTextual(target) ? rest : '');
    } else {
      // 当前块有内容：在下方插入新块
      doc.setText(block.id, rest);
      doc.insertAfter(block, type: target);
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    final hw = HardwareKeyboard.instance;
    final ctrl = hw.isControlPressed || hw.isMetaPressed;
    final shift = hw.isShiftPressed;

    if (_slash.isShowing) {
      final list = filterCommands(_slashQuery);
      if (k == LogicalKeyboardKey.arrowDown) {
        setState(() => _slashIndex = (_slashIndex + 1) % list.length);
        return KeyEventResult.handled;
      }
      if (k == LogicalKeyboardKey.arrowUp) {
        setState(() => _slashIndex = (_slashIndex - 1 + list.length) % list.length);
        return KeyEventResult.handled;
      }
      if (k == LogicalKeyboardKey.enter || k == LogicalKeyboardKey.numpadEnter || k == LogicalKeyboardKey.tab) {
        if (list.isNotEmpty) _applyCommand(list[_slashIndex.clamp(0, list.length - 1)]);
        return KeyEventResult.handled;
      }
      if (k == LogicalKeyboardKey.escape) {
        _slash.hide();
        return KeyEventResult.handled;
      }
    }

    // 撤销 / 重做（文档级）
    if (ctrl && k == LogicalKeyboardKey.keyZ) {
      _flush();
      shift ? doc.redo() : doc.undo();
      return KeyEventResult.handled;
    }
    if (ctrl && k == LogicalKeyboardKey.keyY) {
      _flush();
      doc.redo();
      return KeyEventResult.handled;
    }

    if (!isTextual(type)) {
      if (k == LogicalKeyboardKey.backspace || k == LogicalKeyboardKey.delete) {
        doc.remove(block.id);
        return KeyEventResult.handled;
      }
      if (k == LogicalKeyboardKey.enter) {
        doc.insertAfter(block);
        return KeyEventResult.handled;
      }
      if (k == LogicalKeyboardKey.arrowUp) return _moveFocus(-1) ? KeyEventResult.handled : KeyEventResult.ignored;
      if (k == LogicalKeyboardKey.arrowDown) return _moveFocus(1) ? KeyEventResult.handled : KeyEventResult.ignored;
      return KeyEventResult.ignored;
    }

    final sel = _ctrl.selection;
    final text = _ctrl.text;

    if (ctrl && k == LogicalKeyboardKey.keyB) return _wrap('**');
    if (ctrl && k == LogicalKeyboardKey.keyI) return _wrap('*');
    if (ctrl && k == LogicalKeyboardKey.keyE) return _wrap('`');
    if (ctrl && shift && k == LogicalKeyboardKey.keyS) return _wrap('~~');
    if (ctrl && shift && k == LogicalKeyboardKey.keyK) {
      promptLink();
      return KeyEventResult.handled;
    }

    if (k == LogicalKeyboardKey.enter || k == LogicalKeyboardKey.numpadEnter) {
      if (type == DocType.code && !ctrl) return KeyEventResult.ignored; // 代码块内换行
      if (shift && type != DocType.code) return KeyEventResult.ignored;
      final caret = sel.isValid ? sel.baseOffset.clamp(0, text.length) : text.length;
      _debounce?.cancel();
      _debounce = null;
      final before = type == DocType.code ? text : text.substring(0, caret);
      final after = type == DocType.code ? '' : text.substring(caret);
      _ctrl.text = before;
      doc.split(block.id, before, after);
      return KeyEventResult.handled;
    }

    if (k == LogicalKeyboardKey.backspace && sel.isCollapsed && sel.baseOffset == 0) {
      _debounce?.cancel();
      _debounce = null;
      if (type != DocType.paragraph) {
        doc.setType(block.id, DocType.paragraph, text: text);
        doc.focusRequest.value = FocusRequest(block.id, 0);
      } else if (widget.row.depth > 0) {
        doc.setText(block.id, text);
        doc.outdent(block.id);
        doc.focusRequest.value = FocusRequest(block.id, 0);
      } else if (text.isEmpty) {
        doc.remove(block.id);
      } else {
        doc.mergeWithPrevious(block.id, text);
      }
      return KeyEventResult.handled;
    }

    if (k == LogicalKeyboardKey.tab) {
      _flush();
      shift ? doc.outdent(block.id) : doc.indent(block.id);
      return KeyEventResult.handled;
    }

    if (k == LogicalKeyboardKey.arrowUp && !shift) {
      final caret = sel.baseOffset.clamp(0, text.length);
      if (!text.substring(0, caret).contains('\n') && _moveFocus(-1)) return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowDown && !shift) {
      final caret = sel.baseOffset.clamp(0, text.length);
      if (!text.substring(caret).contains('\n') && _moveFocus(1)) return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.escape) {
      _focus.unfocus();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  KeyEventResult _wrap(String m) {
    _ctrl.wrapSelection(m);
    _onChanged(_ctrl.text);
    return KeyEventResult.handled;
  }

  /// 工具栏调用
  void wrap(String m) => _wrap(m);

  Future<void> promptLink() async {
    final sel = _ctrl.selection;
    final c = TextEditingController(text: 'https://');
    final url = await showDialog<String>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('插入链接'),
        content: TextField(
            controller: c, autofocus: true, onSubmitted: (v) => Navigator.pop(d, v), decoration: const InputDecoration(hintText: 'https://')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(d, c.text), child: const Text('确定')),
        ],
      ),
    );
    if (url == null || url.trim().isEmpty || !mounted) return;
    _ctrl.selection = sel;
    _ctrl.insertLink(url.trim());
    _onChanged(_ctrl.text);
    _focus.requestFocus();
  }

  String? get linkAtCaret => _ctrl.linkAt(_ctrl.selection.baseOffset);

  bool _moveFocus(int dir) {
    final rs = doc.rows();
    var i = rs.indexWhere((r) => r.block.id == block.id) + dir;
    while (i >= 0 && i < rs.length) {
      if (!rs[i].isPage) {
        _flush();
        doc.focusRequest.value = FocusRequest(rs[i].block.id, dir < 0 ? -1 : 0);
        return true;
      }
      i += dir;
    }
    return false;
  }

  // ------------------------------------------------------------- build

  TextStyle _style(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final c = AppColors.of(context);
    final body = tt.bodyLarge!.merge(EditorType.body.style).copyWith(color: c.text);
    switch (type) {
      case DocType.h1:
        return body.merge(EditorType.h1.style);
      case DocType.h2:
        return body.merge(EditorType.h2.style);
      case DocType.h3:
        return body.merge(EditorType.h3.style);
      case DocType.quote:
        return body; // Notion：引用与正文同字号，以左侧竖线区分
      case DocType.code:
        return body.merge(EditorType.code.style).copyWith(fontFamily: FontTokens.mono, fontFamilyFallback: FontTokens.monoFallback);
      case DocType.todo:
        return block.payload['checked'] == true
            ? body.copyWith(color: c.text3, decoration: TextDecoration.lineThrough, decorationColor: c.text3)
            : body;
      default:
        return body;
    }
  }

  String? _placeholder() {
    switch (type) {
      case DocType.h1:
        return '一级标题';
      case DocType.h2:
        return '二级标题';
      case DocType.h3:
        return '三级标题';
      case DocType.bullet:
      case DocType.numbered:
        return '列表';
      case DocType.todo:
        return '待办事项';
      case DocType.toggle:
        return '折叠列表';
      case DocType.quote:
        return '引用';
      case DocType.callout:
        return '输入提示内容…';
      case DocType.code:
        return '// 代码';
      default:
        return _focus.hasFocus ? '输入文字，或输入 "/" 选择块类型' : null;
    }
  }

  Widget _textField(BuildContext context) {
    return CompositedTransformTarget(
      link: _link,
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onKeyEvent: _onKey,
        child: TextField(
          key: ValueKey('field-${block.id}'),
          controller: _ctrl,
          focusNode: _focus,
          maxLines: null,
          minLines: 1,
          style: _style(context),
          keyboardType: TextInputType.multiline,
          textInputAction: TextInputAction.newline,
          onChanged: _onChanged,
          decoration: InputDecoration.collapsed(
            hintText: _placeholder(),
            hintStyle: _style(context).copyWith(color: AppColors.of(context).text3.withValues(alpha: 0.7)),
          ).copyWith(enabledBorder: InputBorder.none, focusedBorder: InputBorder.none, filled: false),
        ),
      ),
    );
  }

  /// 当前块首行的行高（手柄、复选框、项目符号都按它垂直居中）
  double lineBox(BuildContext context) {
    final st = _style(context);
    return (st.fontSize ?? 16) * (st.height ?? 1.5);
  }

  Widget _prefix(BuildContext context) {
    final pal = AppColors.of(context);
    final st = _style(context);
    final lineBox = (st.fontSize ?? 16) * (st.height ?? 1.5);
    Widget box(Widget c) => SizedBox(width: Gap.x3, height: lineBox, child: Center(child: c));
    switch (type) {
      case DocType.bullet:
        final glyph = ['•', '◦', '▪'][widget.row.depth % 3];
        return box(Text(glyph, textScaler: TextScaler.noScaling, style: st.copyWith(fontSize: 18, height: 1.0, color: pal.text)));
      case DocType.numbered:
        return box(Text('${widget.row.number}.', style: st.copyWith(fontFeatures: const [FontFeature.tabularFigures()])));
      case DocType.todo:
        return box(SizedBox(
          width: 18,
          height: 18,
          child: Checkbox(
            key: ValueKey('check-${block.id}'),
            value: block.payload['checked'] == true,
            visualDensity: VisualDensity.compact,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            onChanged: (v) => doc.setPayload(block.id, {'checked': v == true}),
          ),
        ));
      case DocType.toggle:
        final collapsed = block.payload['collapsed'] == true;
        return box(InkWell(
          key: ValueKey('toggle-${block.id}'),
          borderRadius: BorderRadius.circular(AppRadius.xs),
          onTap: () => doc.setPayload(block.id, {'collapsed': !collapsed}),
          child: SizedBox.square(
            dimension: Sizes.iconMd,
            child: AnimatedRotation(
              turns: collapsed ? 0 : 0.25,
              duration: Motion.short4,
              child: Icon(CupertinoIcons.play_arrow_solid, size: 12, color: pal.text2),
            ),
          ),
        ));
      default:
        return const SizedBox.shrink();
    }
  }

  Widget _content(BuildContext context) {
    final pal = AppColors.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    switch (type) {
      case DocType.divider:
        return Focus(
          focusNode: _focus,
          onKeyEvent: _onKey,
          child: GestureDetector(
            onTap: () => _focus.requestFocus(),
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: Gap.l),
              color: _focus.hasFocus ? pal.selected : Colors.transparent,
              child: Divider(height: 1, thickness: 1, color: pal.separator),
            ),
          ),
        );
      case DocType.image:
        return Focus(focusNode: _focus, onKeyEvent: _onKey, child: _ImageBlock(doc: doc, block: block, selected: _focus.hasFocus));
      case DocType.code:
        final lang = (block.payload['lang'] ?? 'plaintext') as String;
        // 代码块（AppFlowy / Notion）：中性灰底、圆角 8；顶部一行 28 高放语言与复制按钮
        return Container(
          key: ValueKey('code-${block.id}'),
          decoration: BoxDecoration(color: pal.fill, borderRadius: BorderRadius.circular(AppRadius.m)),
          padding: const EdgeInsets.fromLTRB(Gap.xl, Gap.xs, Gap.xs, Gap.l),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(
              height: Sizes.compact,
              child: Row(children: [
                PopupMenuButton<String>(
                  tooltip: '选择语言',
                  initialValue: lang,
                  onSelected: (v) => doc.setPayload(block.id, {'lang': v}),
                  itemBuilder: (_) => [for (final l in codeLanguages) PopupMenuItem(height: Sizes.control, value: l, child: Text(l))],
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Text(lang, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: pal.text2)),
                    const SizedBox(width: 2),
                    Icon(CupertinoIcons.chevron_down, size: 10, color: pal.text3),
                  ]),
                ),
                const Spacer(),
                SizedBox.square(
                  dimension: Sizes.compact,
                  child: IconButton(
                    key: ValueKey('copyCode-${block.id}'),
                    tooltip: '复制代码',
                    style: IconButton.styleFrom(fixedSize: const Size.square(Sizes.compact), minimumSize: const Size.square(Sizes.compact)),
                    icon: const Icon(CupertinoIcons.doc_on_doc, size: Sizes.iconSm),
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: _ctrl.text));
                      if (context.mounted) showToast(context, '代码已复制');
                    },
                  ),
                ),
              ]),
            ),
            const SizedBox(height: Gap.xs),
            AnimatedCrossFade(
              duration: Motion.short3,
              crossFadeState: _focus.hasFocus || _ctrl.text.isEmpty ? CrossFadeState.showFirst : CrossFadeState.showSecond,
              firstChild: _textField(context),
              secondChild: GestureDetector(
                onTap: () => _focus.requestFocus(),
                child: SizedBox(
                  width: double.infinity,
                  child: HighlightView(
                    _ctrl.text,
                    language: lang,
                    theme: {
                      ...(dark ? atomOneDarkTheme : githubTheme),
                      'root': TextStyle(backgroundColor: Colors.transparent, color: pal.text),
                    },
                    textStyle: EditorType.code.style.copyWith(fontFamily: FontTokens.mono, fontFamilyFallback: FontTokens.monoFallback),
                  ),
                ),
              ),
            ),
          ]),
        );
      case DocType.quote:
        return Container(
          padding: const EdgeInsets.only(left: Gap.l + 2),
          decoration: BoxDecoration(border: Border(left: BorderSide(color: pal.text, width: 3))),
          child: _textField(context),
        );
      case DocType.callout:
        final icon = (block.payload['icon'] ?? '💡') as String;
        // 提示框（Notion 灰色 callout）：中性灰底、圆角 8；emoji 与首行文字同一行高、垂直居中
        return Container(
          key: ValueKey('callout-${block.id}'),
          padding: const EdgeInsets.fromLTRB(Gap.l, Gap.l, Gap.xl, Gap.l),
          decoration: BoxDecoration(color: pal.fill, borderRadius: BorderRadius.circular(AppRadius.m)),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            InkWell(
              borderRadius: BorderRadius.circular(AppRadius.xs),
              onTap: () async {
                final e = await pickEmoji(context);
                if (e != null) doc.setPayload(block.id, {'icon': e});
              },
              child: SizedBox(width: lineBox(context), height: lineBox(context), child: Center(child: Emoji(icon, size: Sizes.iconMd))),
            ),
            const SizedBox(width: Gap.m),
            Expanded(child: _textField(context)),
          ]),
        );
      default:
        return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _prefix(context),
          if (type == DocType.bullet || type == DocType.numbered || type == DocType.todo || type == DocType.toggle)
            const SizedBox(width: 4),
          Expanded(child: _textField(context)),
        ]);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.row.isPage) return _PageLinkRow(doc: doc, page: block, index: widget.index);
    final topPad = switch (type) {
      DocType.h1 => 18.0,
      DocType.h2 => 14.0,
      DocType.h3 => 10.0,
      _ => 2.0,
    };
    final touch = Theme.of(context).platform == TargetPlatform.android || Theme.of(context).platform == TargetPlatform.iOS;
    final showGutter = _hover || _focus.hasFocus || touch;
    return MouseRegion(
      onEnter: (e) { if (isMouseHover(e)) setState(() => _hover = true); },
      onExit: (_) => setState(() => _hover = false),
      // 渲染到根 Overlay：不被玻璃面板裁剪；空间不足时向上弹出
      child: OverlayPortal(
        overlayLocation: OverlayChildLocation.rootOverlay,
        controller: _slash,
        overlayChildBuilder: (ctx) {
          final box = context.findRenderObject() as RenderBox?;
          final y = box != null && box.attached ? box.localToGlobal(Offset.zero).dy : 0.0;
          final up = y > MediaQuery.sizeOf(ctx).height - 360;
          return CompositedTransformFollower(
          link: _link,
          targetAnchor: up ? Alignment.topLeft : Alignment.bottomLeft,
          followerAnchor: up ? Alignment.bottomLeft : Alignment.topLeft,
          offset: Offset(44, up ? -6 : 6),
          child: Align(
            alignment: up ? Alignment.bottomLeft : Alignment.topLeft,
            child: TextFieldTapRegion(
              child: SlashMenu(
                query: _slashQuery,
                selected: _slashIndex,
                onSelect: _applyCommand,
              ),
            ),
          ),
        );
        },
        child: Padding(
          padding: EdgeInsets.only(top: topPad, bottom: 2, left: 24.0 * widget.row.depth),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            // 拖动手柄与 "+"（悬停时显示）
            AnimatedOpacity(
              duration: Motion.short3,
              opacity: showGutter ? (touch && !_focus.hasFocus ? 0.35 : 1) : 0,
              child: Container(
                width: gutterWidth(context),
                // 手柄（24 高）与首行文字垂直居中
                padding: EdgeInsets.only(top: 3 + ((lineBox(context) - 24) / 2).clamp(0.0, 99.0) + (type == DocType.code ? Gap.xs : 0) + (type == DocType.callout ? Gap.l : 0)),
                child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                  if (!touch && gutterWidth(context) >= 44)
                    _GutterButton(
                      tooltip: '在下方添加块',
                      icon: CupertinoIcons.add,
                      onTap: () => doc.insertAfter(block),
                    ),
                  ReorderableDragStartListener(
                    index: widget.index,
                    enabled: !touch,
                    child: ReorderableDelayedDragStartListener(
                      index: widget.index,
                      enabled: touch,
                      child: _GutterButton(
                        key: ValueKey('handle-${block.id}'),
                        tooltip: '拖动排序 / 点击打开菜单',
                        icon: null,
                        onTap: () => _blockMenu(context),
                        cursor: SystemMouseCursors.grab,
                      ),
                    ),
                  ),
                ]),
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 2),
                child: _content(context),
              ),
            ),
            const SizedBox(width: Gap.m),
          ]),
        ),
      ),
    );
  }

  Future<void> _blockMenu(BuildContext context) async {
    final box = context.findRenderObject() as RenderBox?;
    final pos = box?.localToGlobal(const Offset(20, 24)) ?? Offset.zero;
    final v = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(pos.dx, pos.dy, pos.dx + 1, pos.dy + 1),
      items: [
        menuItem(context, 'dup', CupertinoIcons.doc_on_doc, '复制一份'),
        menuItem(context, 'delete', CupertinoIcons.trash, '删除', danger: true),
        const PopupMenuDivider(height: Gap.m + 1),
        for (final c in slashCommands.where((c) => c.type != null && isTextual(c.type!)))
          menuItem(context, 'type:${c.type!.name}', c.icon, '转换为${c.label}'),
      ],
    );
    if (v == null) return;
    if (v == 'delete') {
      doc.remove(block.id);
    } else if (v == 'dup') {
      doc.insertAfter(block, type: type, text: _ctrl.text, extra: {
        for (final k in ['checked', 'lang', 'icon', 'url', 'file_id']) if (block.payload[k] != null) k: block.payload[k],
      });
    } else if (v.startsWith('type:')) {
      doc.setType(block.id, DocType.values.byName(v.substring(5)), text: _ctrl.text);
    }
  }
}

class _GutterButton extends StatelessWidget {
  final String tooltip;
  final IconData? icon; // null = 六点拖动手柄
  final VoidCallback onTap;
  final MouseCursor cursor;
  const _GutterButton({super.key, required this.tooltip, required this.icon, required this.onTap, this.cursor = SystemMouseCursors.click});

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 600),
      child: MouseRegion(
        cursor: cursor,
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadius.xs),
          hoverColor: c.hover,
          onTap: onTap,
          child: SizedBox(
            width: 20,
            height: 24,
            child: Center(child: icon == null ? DragDots(color: c.text3) : Icon(icon, size: Sizes.iconSm, color: c.text3)),
          ),
        ),
      ),
    );
  }
}

/// 六点拖动手柄（Notion / AppFlowy 的 ⋮⋮ 字形），自绘以免混用第二套图标
class DragDots extends StatelessWidget {
  final Color color;
  const DragDots({super.key, required this.color});
  @override
  Widget build(BuildContext context) => CustomPaint(size: const Size(10, 14), painter: _DotsPainter(color));
}

class _DotsPainter extends CustomPainter {
  final Color color;
  _DotsPainter(this.color);
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()..color = color;
    for (var col = 0; col < 2; col++) {
      for (var row = 0; row < 3; row++) {
        canvas.drawCircle(Offset(2 + col * 6.0, 2 + row * 5.0), 1.5, p);
      }
    }
  }

  @override
  bool shouldRepaint(_DotsPainter old) => old.color != color;
}

/// "/" 命令菜单
class SlashMenu extends StatelessWidget {
  final String query;
  final int selected;
  final void Function(SlashCommand) onSelect;
  const SlashMenu({super.key, required this.query, required this.selected, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final tt = Theme.of(context).textTheme;
    final list = filterCommands(query);
    final maxW = (MediaQuery.sizeOf(context).width - 72).clamp(200.0, 300.0);
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: Motion.medium4,
      curve: springCurve,
      builder: (_, t, child) => Opacity(
          opacity: t.clamp(0.0, 1.0),
          child: Transform.scale(scale: 0.96 + 0.04 * t, alignment: Alignment.topLeft, child: child)),
      child: Glass(
        key: const Key('slashMenu'),
        radius: AppRadius.l,
        child: Material(
          type: MaterialType.transparency,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxW, minWidth: maxW, maxHeight: 320),
            child: list.isEmpty
                ? SizedBox(
                    height: Sizes.bar,
                    child: Center(child: Text('没有匹配的块类型', style: tt.bodyMedium?.copyWith(color: c.text3))),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.all(Gap.xs),
                    shrinkWrap: true,
                    itemCount: list.length,
                    itemBuilder: (context, i) {
                      final cmd = list[i];
                      final sel = i == selected;
                      // 每行 44：32 的图标方块 + 标题 / 说明两行
                      return InkWell(
                        key: ValueKey('slash-${cmd.label}'),
                        borderRadius: BorderRadius.circular(AppRadius.s),
                        onTap: () => onSelect(cmd),
                        child: Container(
                          height: Sizes.bar,
                          padding: const EdgeInsets.symmetric(horizontal: Gap.s),
                          decoration: BoxDecoration(
                            color: sel ? c.selected : Colors.transparent,
                            borderRadius: BorderRadius.circular(AppRadius.s),
                          ),
                          child: Row(children: [
                            Container(
                              width: Sizes.control,
                              height: Sizes.control,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: c.bg,
                                border: Border.all(color: c.separator),
                                borderRadius: BorderRadius.circular(AppRadius.s),
                              ),
                              child: switch (cmd.type) {
                                // Notion：标题命令用 H1/H2/H3 字形而非同一个图标
                                DocType.h1 || DocType.h2 || DocType.h3 => Text('H${cmd.type!.index}',
                                    textScaler: TextScaler.noScaling,
                                    style: TextStyle(fontSize: 12, height: 1.0, fontWeight: FontWeight.w600, color: c.text2)),
                                _ => Icon(cmd.icon, size: Sizes.iconSm, color: c.text2),
                              },
                            ),
                            const SizedBox(width: Gap.m),
                            Expanded(
                              child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                                Text(cmd.label, maxLines: 1, overflow: TextOverflow.ellipsis, style: tt.bodyMedium?.copyWith(color: c.text, height: 1.25)),
                                Text(cmd.hint, maxLines: 1, overflow: TextOverflow.ellipsis, style: tt.bodySmall?.copyWith(color: c.text3, height: 1.25)),
                              ]),
                            ),
                          ]),
                        ),
                      );
                    },
                  ),
          ),
        ),
      ),
    );
  }
}

/// 子页面链接行
class _PageLinkRow extends StatefulWidget {
  final DocController doc;
  final Block page;
  final int index;
  const _PageLinkRow({required this.doc, required this.page, required this.index});
  @override
  State<_PageLinkRow> createState() => _PageLinkRowState();
}

class _PageLinkRowState extends State<_PageLinkRow> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final icon = (widget.page.payload['icon'] ?? '📄') as String;
    return MouseRegion(
      onEnter: (e) { if (isMouseHover(e)) setState(() => _hover = true); },
      onExit: (_) => setState(() => _hover = false),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(children: [
          SizedBox(
            width: gutterWidth(context),
            child: AnimatedOpacity(
              opacity: _hover ? 1 : 0,
              duration: Motion.short3,
              child: Align(
                alignment: Alignment.centerRight,
                child: ReorderableDragStartListener(
                  index: widget.index,
                  child: SizedBox(width: 20, height: 24, child: Center(child: DragDots(color: c.text3))),
                ),
              ),
            ),
          ),
          Expanded(
            child: InkWell(
              key: ValueKey('pageLink-${widget.page.id}'),
              borderRadius: BorderRadius.circular(AppRadius.xs),
              onTap: () => openPage(context, widget.page.id),
              child: Container(
                height: Sizes.control,
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: Row(children: [
                  Emoji(icon, size: Sizes.iconMd),
                  const SizedBox(width: Gap.s),
                  Flexible(
                    child: Text(
                      widget.page.title.isEmpty ? '无标题' : widget.page.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: EditorType.body.style.copyWith(
                        color: c.text,
                        fontWeight: FontWeight.w500,
                        decoration: TextDecoration.underline,
                        decorationColor: c.separator,
                      ),
                    ),
                  ),
                ]),
              ),
            ),
          ),
          const SizedBox(width: 8),
        ]),
      ),
    );
  }
}

/// 图片块：上传到自己的服务器或填写图片链接
class _ImageBlock extends StatelessWidget {
  final DocController doc;
  final Block block;
  final bool selected;
  const _ImageBlock({required this.doc, required this.block, required this.selected});

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final s = AppScope.of(context);
    final url = block.payload['url'] as String?;
    final fileId = block.payload['file_id'] as String?;
    String? src = url;
    if (src == null && fileId != null && s.settings.server != null && s.settings.token != null) {
      src = s.api.fileUrl(s.settings.server!, s.settings.token!, fileId).toString();
    }
    if (src == null) {
      return Container(
        key: ValueKey('imagePlaceholder-${block.id}'),
        padding: const EdgeInsets.all(Gap.l),
        decoration: BoxDecoration(color: c.fill, borderRadius: BorderRadius.circular(AppRadius.m)),
        child: Wrap(spacing: Gap.m, runSpacing: Gap.m, crossAxisAlignment: WrapCrossAlignment.center, children: [
          SizedBox(
            height: Sizes.control,
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(CupertinoIcons.photo, size: Sizes.iconMd, color: c.text2),
              const SizedBox(width: Gap.m),
              Text('添加图片', style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: c.text2)),
            ]),
          ),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(fixedSize: const Size.fromHeight(Sizes.control), minimumSize: const Size(0, Sizes.control), backgroundColor: c.bg),
            icon: const Icon(CupertinoIcons.cloud_upload, size: Sizes.iconSm),
            label: const Text('上传'),
            onPressed: () async {
              final files = await FilePicker.pickFiles(type: FileType.image);
              if (files.isEmpty) return;
              final f = files.first;
              final bytes = await f.xFile.readAsBytes();
              try {
                final id = await s.api.uploadFile(s.settings.server!, s.settings.token!, f.name, bytes);
                doc.setPayload(block.id, {'file_id': id, 'name': f.name});
              } catch (e) {
                if (context.mounted) {
                  showToast(context, '上传失败（需在线）：$e');
                }
              }
            },
          ),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(fixedSize: const Size.fromHeight(Sizes.control), minimumSize: const Size(0, Sizes.control), backgroundColor: c.bg),
            icon: const Icon(CupertinoIcons.link, size: Sizes.iconSm),
            label: const Text('图片链接'),
            onPressed: () async {
              final c = TextEditingController();
              final v = await showDialog<String>(
                context: context,
                builder: (d) => AlertDialog(
                  title: const Text('图片链接'),
                  content: TextField(controller: c, autofocus: true, decoration: const InputDecoration(hintText: 'https://…'), onSubmitted: (v) => Navigator.pop(d, v)),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(d), child: const Text('取消')),
                    FilledButton(onPressed: () => Navigator.pop(d, c.text), child: const Text('确定')),
                  ],
                ),
              );
              if (v != null && v.trim().isNotEmpty) doc.setPayload(block.id, {'url': v.trim()});
            },
          ),
        ]),
      );
    }
    return AnimatedContainer(
      duration: Motion.short3,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadius.m),
        border: Border.all(color: selected ? c.accent : Colors.transparent, width: 2),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppRadius.s),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 420),
          child: Image.network(
            src,
            fit: BoxFit.contain,
            loadingBuilder: (ctx, child, p) => p == null
                ? child
                : Container(
                    height: 120,
                    color: c.fill,
                    child: const Center(child: SizedBox.square(dimension: Sizes.iconMd, child: CircularProgressIndicator(strokeWidth: 2))),
                  ),
            errorBuilder: (ctx, e, st) => Container(
              key: const Key('imageError'),
              height: 80,
              color: c.fill,
              child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                Icon(CupertinoIcons.exclamationmark_triangle, size: Sizes.iconSm, color: c.text3),
                const SizedBox(width: Gap.m),
                Text('图片加载失败', style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: c.text3)),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

/// 左侧手柄栏宽度：宽屏 44（"+" 与拖动手柄），窄屏 24（仅手柄）。
double gutterWidth(BuildContext context) => MediaQuery.sizeOf(context).width < 600 ? 24.0 : 44.0;

/// 打开链接
Future<void> launchLink(String url) async {
  final u = Uri.tryParse(url);
  if (u != null) await launchUrl(u, mode: LaunchMode.externalApplication);
}

const _emojis = [
  '📄', '📝', '📌', '📎', '📚', '📖', '🗂️', '📁', '💡', '⭐', '🔥', '✅', '❗', '❓', '⚠️', '🎯',
  '🚀', '🧠', '💼', '🏠', '🛒', '💰', '📅', '⏰', '🎉', '❤️', '🌱', '🍀', '☕', '🎵', '🎨', '🔧',
  '💻', '📱', '🐞', '🔒', '🌏', '✈️', '🍜', '🏃', '😀', '😎', '🤔', '👍', '🙏', '🐱', '🐶', '🌙',
];

Future<String?> pickEmoji(BuildContext context, {bool allowRemove = false}) => showDialog<String>(
      context: context,
      builder: (c) {
        // 8 列 × 40 的网格；窄屏自动减少列数，不会溢出
        final w = (MediaQuery.sizeOf(c).width - 96).clamp(200.0, 8 * 40.0 + 7 * Gap.xs);
        return AlertDialog(
          title: const Text('选择图标'),
          content: SizedBox(
            width: w,
            child: SingleChildScrollView(
              child: Wrap(spacing: Gap.xs, runSpacing: Gap.xs, children: [
                for (final e in _emojis)
                  InkWell(
                    key: ValueKey('emoji-$e'),
                    borderRadius: BorderRadius.circular(AppRadius.s),
                    onTap: () => Navigator.pop(c, e),
                    child: SizedBox.square(dimension: 40, child: Center(child: Emoji(e, size: 28))),
                  ),
              ]),
            ),
          ),
          actions: [
            if (allowRemove) TextButton(onPressed: () => Navigator.pop(c, ''), child: const Text('移除')),
            TextButton(onPressed: () => Navigator.pop(c), child: const Text('取消')),
          ],
        );
      },
    );
