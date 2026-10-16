import 'dart:async';
import '../ui/tokens.dart';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_scope.dart';
import '../models/block.dart';
import 'block_row.dart';
import 'commands.dart';
import 'doc.dart';
import 'page_nav.dart';

/// 封面预设（渐变）
/// 封面预设：低饱和、柔和的渐变（参考 Notion 封面与 Apple 壁纸的雾面色调）。
/// 键名与旧版保持兼容（已同步的数据仍可显示）。
const coverPresets = <String, List<Color>>{
  'sky': [Color(0xFFDCE7F3), Color(0xFFC3D5EA)],
  'ocean': [Color(0xFFB9CEDF), Color(0xFF9DB7CE)],
  'mint': [Color(0xFFDDEBE3), Color(0xFFC4DCCF)],
  'forest': [Color(0xFFB7C9B5), Color(0xFF93AD92)],
  'peach': [Color(0xFFF6E3D6), Color(0xFFEBCDBA)],
  'sunset': [Color(0xFFF1D9D3), Color(0xFFE3BFC0)],
  'lavender': [Color(0xFFE3DDEE), Color(0xFFCFC6E3)],
  'night': [Color(0xFF3B4250), Color(0xFF262B35)],
};

/// Notion 式页面：封面、图标、标题、面包屑、块编辑器。
class PageScreen extends StatefulWidget {
  final String pageId;

  /// 作为独立路由（手机）打开时显示返回按钮
  final bool standalone;
  final VoidCallback? onMenu;
  const PageScreen({super.key, required this.pageId, this.standalone = false, this.onMenu});

  @override
  State<PageScreen> createState() => _PageScreenState();
}

class _PageScreenState extends State<PageScreen> {
  DocController? _doc;
  final _title = TextEditingController();
  final _titleFocus = FocusNode();
  final _rowKeys = <String, GlobalKey<BlockRowState>>{};
  Timer? _titleDebounce;
  bool _headerHover = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_doc == null) {
      final sync = AppScope.of(context).sync;
      _doc = DocController(sync, widget.pageId);
      _title.text = _doc!.page?.title ?? '';
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) sync.setViewed(widget.pageId, true);
      });
      // 新建的空页面：直接聚焦标题
      if (_title.text.isEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _titleFocus.requestFocus());
      }
    }
  }

  @override
  void didUpdateWidget(covariant PageScreen old) {
    super.didUpdateWidget(old);
    if (old.pageId != widget.pageId) {
      _flushTitle();
      _doc?.dispose();
      _doc = DocController(AppScope.of(context).sync, widget.pageId);
      _title.text = _doc!.page?.title ?? '';
      _rowKeys.clear();
    }
  }

  @override
  void dispose() {
    _flushTitle();
    _doc?.dispose();
    _title.dispose();
    _titleFocus.dispose();
    super.dispose();
  }

  void _flushTitle() {
    if (_titleDebounce != null) {
      _titleDebounce!.cancel();
      _titleDebounce = null;
      _doc?.sync.update(widget.pageId, title: _title.text.trim());
    }
  }

  void _onTitle(String v) {
    _titleDebounce?.cancel();
    _titleDebounce = Timer(const Duration(milliseconds: 400), () {
      _titleDebounce = null;
      _doc?.sync.update(widget.pageId, title: v.trim());
    });
  }

  void _titleEnter() {
    _flushTitle();
    final doc = _doc!;
    final rows = doc.rows();
    if (rows.isNotEmpty && !rows.first.isPage && isTextual(rows.first.type) && docText(rows.first.block).isEmpty) {
      doc.focusRequest.value = FocusRequest(rows.first.block.id, 0);
    } else {
      doc.insertFirst();
    }
  }

  BlockRowState? get _focusedRow {
    final id = _doc?.focusedId.value;
    return id == null ? null : _rowKeys[id]?.currentState;
  }

  @override
  Widget build(BuildContext context) {
    final doc = _doc!;
    final cs = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: doc,
      builder: (context, _) {
        final page = doc.page;
        if (page == null || page.deleted) {
          return Scaffold(
            appBar: AppBar(),
            body: _Empty(icon: CupertinoIcons.trash, title: '页面已被删除', subtitle: '可以从侧边栏打开其他页面'),
          );
        }
        // 远程修改标题时同步（本地未在编辑）
        if (!_titleFocus.hasFocus && _titleDebounce == null && _title.text != page.title) _title.text = page.title;
        final rows = doc.rows();
        for (final r in rows) {
          _rowKeys.putIfAbsent(r.block.id, () => GlobalKey<BlockRowState>());
        }
        final wide = MediaQuery.sizeOf(context).width >= 720;
        // 文字左边缘（标题、图标、正文对齐线）。正文行 = 行左内边距 + 手柄栏 + 2
        final hPad = wide ? 56.0 : 28.0;
        return CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.keyZ, control: true): doc.undo,
            const SingleActivator(LogicalKeyboardKey.keyZ, control: true, shift: true): doc.redo,
            const SingleActivator(LogicalKeyboardKey.keyY, control: true): doc.redo,
          },
          child: Scaffold(
            backgroundColor: Colors.transparent,
            appBar: AppBar(
              automaticallyImplyLeading: widget.standalone,
              leading: widget.onMenu != null
                  ? IconButton(icon: const Icon(CupertinoIcons.sidebar_left), tooltip: '菜单', onPressed: widget.onMenu)
                  : null,
              titleSpacing: widget.standalone || widget.onMenu != null ? 0 : 16,
              scrolledUnderElevation: 0,
              backgroundColor: Colors.transparent,
              title: _Breadcrumbs(doc: doc, page: page),
              actions: [
                IconButton(
                  tooltip: '撤销 (Ctrl+Z)',
                  icon: const Icon(CupertinoIcons.arrow_uturn_left),
                  onPressed: doc.canUndo ? doc.undo : null,
                ),
                IconButton(
                  tooltip: '重做 (Ctrl+Shift+Z)',
                  icon: const Icon(CupertinoIcons.arrow_uturn_right),
                  onPressed: doc.canRedo ? doc.redo : null,
                ),
                _PageMenu(doc: doc, page: page),
                const SizedBox(width: 4),
              ],
            ),
            body: Column(children: [
              Expanded(
                child: CustomScrollView(
                  slivers: [
                    SliverToBoxAdapter(child: _pageHead(context, page, rows.isEmpty, hPad)),
                    SliverPadding(
                      padding: EdgeInsets.symmetric(horizontal: wide ? 0 : 0),
                      sliver: SliverReorderableList(
                        itemCount: rows.length,
                        // onReorderItem 的 toIndex 已扣除被移走的一项；moveRow 使用 onReorder 语义
                        onReorderItem: (from, to) => doc.moveRow(from, to > from ? to + 1 : to),
                        proxyDecorator: (child, i, a) => Material(
                          elevation: 6,
                          color: cs.surface,
                          shadowColor: Colors.black26,
                          borderRadius: BorderRadius.circular(6),
                          child: child,
                        ),
                        itemBuilder: (context, i) {
                          final r = rows[i];
                          return Center(
                            key: ValueKey('row-${r.block.id}'),
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: EditorType.maxWidth),
                              child: Padding(
                                padding: EdgeInsets.only(left: (hPad - gutterWidth(context) - 2).clamp(0.0, 999.0), right: hPad),
                                child: _AppearOnce(
                                  id: r.block.id,
                                  child: BlockRow(key: _rowKeys[r.block.id], doc: doc, row: r, index: i),
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                    SliverToBoxAdapter(child: _footer(context, rows)),
                  ],
                ),
              ),
              ValueListenableBuilder<String?>(
                valueListenable: doc.focusedId,
                builder: (context, id, _) => AnimatedSwitcher(
                  duration: Motion.short4,
                  transitionBuilder: (c, a) => SizeTransition(sizeFactor: a, alignment: Alignment.topCenter, child: c),
                  child: id == null ? const SizedBox.shrink() : _Toolbar(key: const ValueKey('toolbar'), doc: doc, row: () => _focusedRow),
                ),
              ),
            ]),
          ),
        );
      },
    );
  }

  /// 页面头部：封面 + 压在封面下沿的图标（Notion 布局：图标约一半在封面上、在最上层、完整可见），
  /// 然后是悬停操作和标题。图标与内容列左对齐。
  Widget _pageHead(BuildContext context, Block page, bool empty, double hPad) {
    final icon = page.payload['icon'] as String?;
    final hasIcon = icon != null && icon.isNotEmpty;
    final colors = coverPresets[page.payload['cover']];
    final hasCover = colors != null;
    return LayoutBuilder(builder: (context, c) {
      final narrow = c.maxWidth < 600;
      final coverH = narrow ? 150.0 : EditorType.coverHeight;
      final iconBox = narrow ? 64.0 : EditorType.iconSize;
      final contentW = c.maxWidth.clamp(0.0, EditorType.maxWidth);
      final left = (c.maxWidth - contentW) / 2 + hPad;
      // 图标压住封面下沿 ~45%
      final overlap = iconBox * 0.45;
      final iconWidget = _iconButton(context, page, icon ?? '', iconBox);
      return Stack(clipBehavior: Clip.none, children: [
        Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (hasCover)
            _cover(context, page, colors, coverH)
          else
            SizedBox(height: narrow ? 28 : 56),
          // 为图标留位：有封面时只留下沿以下部分
          if (hasIcon) SizedBox(height: hasCover ? iconBox - overlap + 4 : iconBox + 4) else SizedBox(height: hasCover ? 12 : 0),
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: EditorType.maxWidth),
              child: Padding(padding: EdgeInsets.symmetric(horizontal: hPad), child: _header(context, page, empty)),
            ),
          ),
        ]),
        if (hasIcon)
          Positioned(
            key: const Key('pageIconPos'),
            left: left - 6,
            top: hasCover ? coverH - overlap : (narrow ? 28 : 56),
            child: iconWidget,
          ),
      ]);
    });
  }

  Widget _iconButton(BuildContext context, Block page, String icon, double box) => Material(
        type: MaterialType.transparency,
        child: InkWell(
          key: const Key('pageIcon'),
          borderRadius: BorderRadius.circular(Radii.small),
          onTap: () async {
            final e = await pickEmoji(context, allowRemove: true);
            if (e != null) _doc!.sync.update(page.id, payload: {...page.payload, 'icon': e.isEmpty ? null : e});
          },
          child: SizedBox(
            width: box + 12,
            height: box,
            child: Center(child: Text(icon, style: TextStyle(fontSize: box * 0.82, height: 1.0))),
          ),
        ),
      );

  Widget _cover(BuildContext context, Block page, List<Color> colors, double height) {
    return GestureDetector(
      onTap: () => _pickCover(page),
      child: Container(
        key: const Key('pageCover'),
        height: height,
        width: double.infinity,
        decoration: BoxDecoration(gradient: LinearGradient(colors: colors, begin: Alignment.topLeft, end: Alignment.bottomRight)),
      ),
    );
  }

  Future<void> _pickCover(Block page) async {
    final v = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('选择封面', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 12),
            Wrap(spacing: 10, runSpacing: 10, children: [
              for (final e in coverPresets.entries)
                InkWell(
                  onTap: () => Navigator.pop(c, e.key),
                  borderRadius: BorderRadius.circular(8),
                  child: Container(
                    width: 96,
                    height: 54,
                    decoration: BoxDecoration(borderRadius: BorderRadius.circular(8), gradient: LinearGradient(colors: e.value)),
                  ),
                ),
            ]),
            const SizedBox(height: 8),
            TextButton.icon(onPressed: () => Navigator.pop(c, ''), icon: const Icon(CupertinoIcons.xmark), label: const Text('移除封面')),
          ]),
        ),
      ),
    );
    if (v == null) return;
    _doc!.sync.update(page.id, payload: {...page.payload, 'cover': v.isEmpty ? null : v});
  }

  Widget _header(BuildContext context, Block page, bool empty) {
    final cs = Theme.of(context).colorScheme;
    final icon = page.payload['icon'] as String?;
    final hasCover = coverPresets.containsKey(page.payload['cover']);
    return MouseRegion(
      onEnter: (_) => setState(() => _headerHover = true),
      onExit: (_) => setState(() => _headerHover = false),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        AnimatedOpacity(
          duration: Motion.short3,
          opacity: _headerHover || empty || Theme.of(context).platform == TargetPlatform.android ? 1 : 0,
          child: Wrap(spacing: 4, children: [
            if (icon == null || icon.isEmpty)
              TextButton.icon(
                style: TextButton.styleFrom(foregroundColor: cs.outline),
                onPressed: () async {
                  final e = await pickEmoji(context);
                  if (e != null) _doc!.sync.update(page.id, payload: {...page.payload, 'icon': e});
                },
                icon: const Icon(CupertinoIcons.smiley, size: 18),
                label: const Text('添加图标'),
              ),
            if (!hasCover)
              TextButton.icon(
                key: const Key('addCover'),
                style: TextButton.styleFrom(foregroundColor: cs.outline),
                onPressed: () => _pickCover(page),
                icon: const Icon(CupertinoIcons.photo, size: 18),
                label: const Text('添加封面'),
              ),
          ]),
        ),
        TextField(
          key: const Key('pageTitle'),
          controller: _title,
          focusNode: _titleFocus,
          onChanged: _onTitle,
          onSubmitted: (_) => _titleEnter(),
          maxLines: null,
          textInputAction: TextInputAction.next,
          style: Theme.of(context).textTheme.headlineLarge?.merge(EditorType.pageTitle.style),
          decoration: InputDecoration.collapsed(
            hintText: '无标题',
            hintStyle: EditorType.pageTitle.style.copyWith(color: cs.outline.withValues(alpha: 0.5)),
          ).copyWith(enabledBorder: InputBorder.none, focusedBorder: InputBorder.none, filled: false),
        ),
        const SizedBox(height: 12),
      ]),
    );
  }

  Widget _footer(BuildContext context, List<DocRow> rows) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: EditorType.maxWidth),
        child: GestureDetector(
          key: const Key('pageFooter'),
          behavior: HitTestBehavior.opaque,
          onTap: () {
            final doc = _doc!;
            final last = rows.isEmpty ? null : rows.last;
            if (last != null && !last.isPage && last.type == DocType.paragraph && docText(last.block).isEmpty) {
              doc.focusRequest.value = FocusRequest(last.block.id, 0);
            } else {
              doc.insertAfter(null);
            }
          },
          child: Container(
            height: 160,
            alignment: Alignment.topLeft,
            padding: const EdgeInsets.fromLTRB(48, 8, 48, 0),
            child: rows.isEmpty
                ? Text('点击这里开始输入，或输入 "/" 选择块类型', style: TextStyle(color: cs.outline))
                : const SizedBox.shrink(),
          ),
        ),
      ),
    );
  }
}

/// 新出现的块淡入 + 展开动画（只在首次出现时播放）
class _AppearOnce extends StatefulWidget {
  final String id;
  final Widget child;
  const _AppearOnce({required this.id, required this.child});
  static final Set<String> _seen = {};
  @override
  State<_AppearOnce> createState() => _AppearOnceState();
}

class _AppearOnceState extends State<_AppearOnce> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: Motion.short4);
  @override
  void initState() {
    super.initState();
    if (_AppearOnce._seen.add(widget.id)) {
      _c.forward();
    } else {
      _c.value = 1;
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final a = CurvedAnimation(parent: _c, curve: Curves.easeOutCubic);
    return SizeTransition(sizeFactor: a, alignment: Alignment.topCenter, child: FadeTransition(opacity: a, child: widget.child));
  }
}

class _Breadcrumbs extends StatelessWidget {
  final DocController doc;
  final Block page;
  const _Breadcrumbs({required this.doc, required this.page});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final crumbs = [...doc.breadcrumbs(), page];
    Widget crumb(Block b, bool last) {
      final icon = b.kind == BlockKind.folder ? '📁' : (b.payload['icon'] ?? '') as String;
      final label = '${icon.isEmpty ? '' : '$icon '}${b.title.isEmpty ? '无标题' : b.title}';
      return InkWell(
        borderRadius: BorderRadius.circular(4),
        onTap: last || b.kind != BlockKind.page ? null : () => openPage(context, b.id),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          child: Text(label,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 14, color: last ? cs.onSurface : cs.onSurfaceVariant)),
        ),
      );
    }

    return SingleChildScrollView(
      key: const Key('breadcrumbs'),
      scrollDirection: Axis.horizontal,
      reverse: true,
      child: Row(children: [
        for (var i = 0; i < crumbs.length; i++) ...[
          if (i > 0) Text('/', style: TextStyle(color: cs.outlineVariant)),
          crumb(crumbs[i], i == crumbs.length - 1),
        ],
      ]),
    );
  }
}

class _PageMenu extends StatelessWidget {
  final DocController doc;
  final Block page;
  const _PageMenu({required this.doc, required this.page});

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: '更多',
      icon: const Icon(CupertinoIcons.ellipsis),
      onSelected: (v) async {
        switch (v) {
          case 'sub':
            final id = doc.createSubpage(null);
            openPage(context, id);
          case 'global':
            doc.sync.update(page.id,
                viewedMode: page.viewedMode == ViewedMode.global ? ViewedMode.perDevice : ViewedMode.global);
          case 'delete':
            final ok = await showDialog<bool>(
              context: context,
              builder: (c) => AlertDialog(
                title: const Text('删除页面？'),
                content: const Text('页面中的所有内容和子页面都会被删除。'),
                actions: [
                  TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('取消')),
                  FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('删除')),
                ],
              ),
            );
            if (ok == true) {
              doc.sync.delete(page.id);
              if (context.mounted && Navigator.of(context).canPop()) Navigator.of(context).maybePop();
            }
        }
      },
      itemBuilder: (_) => [
        const PopupMenuItem(value: 'sub', child: ListTile(leading: Icon(Icons.note_add_outlined), title: Text('新建子页面'), dense: true)),
        PopupMenuItem(
            value: 'global',
            child: ListTile(
                leading: const Icon(CupertinoIcons.globe),
                title: Text(page.viewedMode == ViewedMode.global ? '改为按设备已读' : '改为全局已读'),
                dense: true)),
        const PopupMenuDivider(),
        const PopupMenuItem(value: 'delete', child: ListTile(leading: Icon(CupertinoIcons.trash), title: Text('删除页面'), dense: true)),
      ],
    );
  }
}

/// 编辑工具栏（聚焦块时出现在底部）：转换类型、行内格式、缩进、撤销重做。
class _Toolbar extends StatelessWidget {
  final DocController doc;
  final BlockRowState? Function() row;
  const _Toolbar({super.key, required this.doc, required this.row});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    Widget b(String tip, IconData icon, VoidCallback? f, {Key? key}) => IconButton(
          key: key,
          tooltip: tip,
          visualDensity: VisualDensity.compact,
          icon: Icon(icon, size: 20),
          onPressed: f,
        );
    return TextFieldTapRegion(
      child: Material(
        color: cs.surfaceContainer,
        child: SafeArea(
          top: false,
          child: SizedBox(
            height: 46,
            child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 8), children: [
              PopupMenuButton<DocType>(
                tooltip: '转换块类型',
                icon: const Icon(Icons.text_fields, size: 20),
                onSelected: (t) {
                  final id = doc.focusedId.value;
                  if (id == null) return;
                  doc.setType(id, t, text: docText(doc.sync.byId(id)!));
                },
                itemBuilder: (_) => [
                  for (final c in slashCommands.where((c) => c.type != null && isTextual(c.type!)))
                    PopupMenuItem(value: c.type, child: Row(children: [Icon(c.icon, size: 18), const SizedBox(width: 10), Text(c.label)])),
                ],
              ),
              b('粗体 (Ctrl+B)', CupertinoIcons.bold, () => row()?.wrap('**'), key: const Key('tbBold')),
              b('斜体 (Ctrl+I)', CupertinoIcons.italic, () => row()?.wrap('*')),
              b('行内代码 (Ctrl+E)', Icons.code, () => row()?.wrap('`')),
              b('删除线 (Ctrl+Shift+S)', CupertinoIcons.strikethrough, () => row()?.wrap('~~')),
              b('链接 (Ctrl+Shift+K)', CupertinoIcons.link, () => row()?.promptLink()),
              b('打开链接', CupertinoIcons.arrow_up_right_square, () {
                final url = row()?.linkAtCaret;
                if (url != null) launchLink(url);
              }),
              const VerticalDivider(indent: 10, endIndent: 10),
              b('增加缩进 (Tab)', CupertinoIcons.increase_indent, () {
                final id = doc.focusedId.value;
                if (id != null) doc.indent(id);
              }),
              b('减少缩进 (Shift+Tab)', CupertinoIcons.decrease_indent, () {
                final id = doc.focusedId.value;
                if (id != null) doc.outdent(id);
              }),
              b('删除此块', CupertinoIcons.trash, () {
                final id = doc.focusedId.value;
                if (id != null) doc.remove(id);
              }),
              const VerticalDivider(indent: 10, endIndent: 10),
              b('撤销', CupertinoIcons.arrow_uturn_left, doc.canUndo ? doc.undo : null),
              b('重做', CupertinoIcons.arrow_uturn_right, doc.canRedo ? doc.redo : null),
              b('完成', Icons.keyboard_hide_outlined, () => FocusManager.instance.primaryFocus?.unfocus()),
            ]),
          ),
        ),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  const _Empty({required this.icon, required this.title, required this.subtitle});
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 48, color: cs.outlineVariant),
        const SizedBox(height: 12),
        Text(title, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(subtitle, style: TextStyle(color: cs.outline)),
      ]),
    );
  }
}
