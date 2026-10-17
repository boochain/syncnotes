import '../ui/block_card.dart' show EmptyState;
import '../ui/ds.dart';
import '../ui/glass.dart';
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
    final c = AppColors.of(context);
    return ListenableBuilder(
      listenable: doc,
      builder: (context, _) {
        final page = doc.page;
        if (page == null || page.deleted || doc.sync.isHidden(page)) {
          return Scaffold(
            appBar: AppBar(),
            body: const EmptyState(icon: CupertinoIcons.trash, title: '页面已被删除', subtitle: '可以从侧边栏打开其他页面'),
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
            backgroundColor: c.bg,
            appBar: AppBar(
              automaticallyImplyLeading: widget.standalone,
              leading: widget.onMenu != null
                  ? IconButton(icon: const Icon(CupertinoIcons.sidebar_left), tooltip: '菜单', onPressed: widget.onMenu)
                  : null,
              titleSpacing: widget.standalone || widget.onMenu != null ? 0 : 16,
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
                const SizedBox(width: Gap.s),
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
                          color: c.elevated,
                          shadowColor: Colors.black26,
                          borderRadius: BorderRadius.circular(AppRadius.s),
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

  /// 页面头部（照 AppFlowy / Notion）：纯色封面 + 压在封面下沿的 60px 图标（约一半在封面上、位于最上层），
  /// 然后是悬停操作（28 高）和 36/600 标题。图标、标题、正文共用同一条左对齐线。
  Widget _pageHead(BuildContext context, Block page, bool empty, double hPad) {
    final icon = page.payload['icon'] as String?;
    final hasIcon = icon != null && icon.isNotEmpty;
    final tone = coverToneKey(page.payload['cover']);
    final hasCover = tone != null;
    return LayoutBuilder(builder: (context, c) {
      final narrow = c.maxWidth < 600;
      final coverH = narrow ? 160.0 : EditorType.coverHeight;
      const iconBox = EditorType.iconSize;
      final contentW = c.maxWidth.clamp(0.0, EditorType.maxWidth);
      final left = (c.maxWidth - contentW) / 2 + hPad;
      const overlap = iconBox * 0.5;
      final topGap = narrow ? Gap.x3 : Gap.x4 + Gap.l;
      return Stack(key: const Key('pageHead'), clipBehavior: Clip.none, children: [
        Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (hasCover) _cover(context, page, tone, coverH) else SizedBox(height: topGap),
          if (hasIcon) SizedBox(height: hasCover ? iconBox - overlap + Gap.l : iconBox + Gap.l) else SizedBox(height: hasCover ? Gap.l : 0),
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
            left: left - Gap.xs,
            top: hasCover ? coverH - overlap : topGap,
            child: _iconButton(context, page, icon, iconBox),
          ),
      ]);
    });
  }

  Widget _iconButton(BuildContext context, Block page, String icon, double box) => Material(
        type: MaterialType.transparency,
        child: InkWell(
          key: const Key('pageIcon'),
          borderRadius: BorderRadius.circular(AppRadius.m),
          onTap: () async {
            final e = await pickEmoji(context, allowRemove: true);
            if (e != null) _doc!.sync.update(page.id, payload: {...page.payload, 'icon': e.isEmpty ? null : e});
          },
          child: Padding(padding: const EdgeInsets.all(Gap.xs), child: Emoji(icon, size: box - Gap.m)),
        ),
      );

  Widget _cover(BuildContext context, Block page, String tone, double height) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final (light, darkC) = coverTones[tone]!;
    return GestureDetector(
      onTap: () => _pickCover(page),
      child: Container(key: const Key('pageCover'), height: height, width: double.infinity, color: dark ? darkC : light),
    );
  }

  Future<void> _pickCover(Block page) async {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final current = coverToneKey(page.payload['cover']);
    final v = await showModalBottomSheet<String>(
      context: context,
      constraints: const BoxConstraints(maxWidth: 520),
      builder: (c) {
        final pal = AppColors.of(c);
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(Gap.xl, 0, Gap.xl, Gap.xl),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text('封面', style: Theme.of(c).textTheme.titleMedium),
              const SizedBox(height: Gap.l),
              Wrap(key: const Key('coverPicker'), spacing: Gap.m, runSpacing: Gap.m, children: [
                for (final e in coverTones.entries)
                  Semantics(
                    button: true,
                    label: coverLabels[e.key],
                    selected: e.key == current,
                    child: InkWell(
                      key: Key('cover-${e.key}'),
                      onTap: () => Navigator.pop(c, e.key),
                      borderRadius: BorderRadius.circular(AppRadius.m),
                      child: Column(children: [
                        Container(
                          width: 88,
                          height: 52,
                          decoration: BoxDecoration(
                            color: dark ? e.value.$2 : e.value.$1,
                            borderRadius: BorderRadius.circular(AppRadius.m),
                            border: Border.all(color: e.key == current ? pal.accent : pal.separator, width: e.key == current ? 2 : 1),
                          ),
                        ),
                        const SizedBox(height: Gap.xs),
                        Text(coverLabels[e.key]!, style: Theme.of(c).textTheme.bodySmall),
                      ]),
                    ),
                  ),
              ]),
              const SizedBox(height: Gap.l),
              if (current != null)
                Align(alignment: Alignment.centerLeft, child: TextButton.icon(
                  key: const Key('removeCover'),
                  onPressed: () => Navigator.pop(c, ''),
                  icon: const Icon(CupertinoIcons.xmark, size: Sizes.iconSm),
                  label: const Text('移除封面'),
                )),
            ]),
          ),
        );
      },
    );
    if (v == null) return;
    _doc!.sync.update(page.id, payload: {...page.payload, 'cover': v.isEmpty ? null : v});
  }

  Widget _header(BuildContext context, Block page, bool empty) {
    final c = AppColors.of(context);
    final icon = page.payload['icon'] as String?;
    final hasCover = coverToneKey(page.payload['cover']) != null;
    final touch = Theme.of(context).platform == TargetPlatform.android || Theme.of(context).platform == TargetPlatform.iOS;
    Widget action(Key key, IconData i, String label, VoidCallback onTap) => TextButton.icon(
          key: key,
          style: TextButton.styleFrom(
            foregroundColor: c.text2,
            fixedSize: const Size.fromHeight(Sizes.compact),
            minimumSize: const Size(0, Sizes.compact),
            padding: const EdgeInsets.symmetric(horizontal: Gap.m),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.s)),
            textStyle: Theme.of(context).textTheme.bodyMedium,
          ),
          onPressed: onTap,
          icon: Icon(i, size: Sizes.iconSm),
          label: Text(label),
        );
    final title = MediaQuery.sizeOf(context).width < 600 ? EditorType.h1 : EditorType.pageTitle;
    return MouseRegion(
      onEnter: (_) => setState(() => _headerHover = true),
      onExit: (_) => setState(() => _headerHover = false),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if ((icon == null || icon.isEmpty) || !hasCover)
          AnimatedOpacity(
            duration: Motion.short3,
            opacity: _headerHover || empty || touch ? 1 : 0,
            child: Padding(
              padding: const EdgeInsets.only(bottom: Gap.xs),
              child: Wrap(spacing: Gap.xs, children: [
                if (icon == null || icon.isEmpty)
                  action(const Key('addIcon'), CupertinoIcons.smiley, '添加图标', () async {
                    final e = await pickEmoji(context);
                    if (e != null) _doc!.sync.update(page.id, payload: {...page.payload, 'icon': e});
                  }),
                if (!hasCover) action(const Key('addCover'), CupertinoIcons.photo, '添加封面', () => _pickCover(page)),
              ]),
            ),
          ),
        TextField(
          key: const Key('pageTitle'),
          controller: _title,
          focusNode: _titleFocus,
          onChanged: _onTitle,
          onSubmitted: (_) => _titleEnter(),
          maxLines: null,
          textInputAction: TextInputAction.next,
          style: Theme.of(context).textTheme.headlineLarge?.merge(title.style).copyWith(color: c.text),
          decoration: InputDecoration.collapsed(
            hintText: '无标题',
            hintStyle: title.style.copyWith(color: c.text3.withValues(alpha: 0.6)),
          ).copyWith(enabledBorder: InputBorder.none, focusedBorder: InputBorder.none, filled: false),
        ),
        const SizedBox(height: Gap.l),
      ]),
    );
  }

  Widget _footer(BuildContext context, List<DocRow> rows) {
    final c = AppColors.of(context);
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
            padding: EdgeInsets.fromLTRB(MediaQuery.sizeOf(context).width >= 720 ? 56 : 28, Gap.m, Gap.xl, 0),
            child: rows.isEmpty
                ? Text('点击这里开始输入，或输入 "/" 选择块类型', style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: c.text3))
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
    final c = AppColors.of(context);
    final tt = Theme.of(context).textTheme;
    final crumbs = [...doc.breadcrumbs(), page];
    Widget crumb(Block b, bool last) {
      final icon = b.kind == BlockKind.folder ? '📁' : (b.payload['icon'] ?? '') as String;
      return InkWell(
        borderRadius: BorderRadius.circular(AppRadius.xs),
        onTap: last || b.kind != BlockKind.page ? null : () => openPage(context, b.id),
        child: Container(
          height: Sizes.compact,
          constraints: const BoxConstraints(maxWidth: 240),
          padding: const EdgeInsets.symmetric(horizontal: Gap.xs),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            if (icon.isNotEmpty) ...[Emoji(icon, size: Sizes.iconSm), const SizedBox(width: Gap.xs)],
            Flexible(
              child: Text(b.title.isEmpty ? '无标题' : b.title,
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: tt.bodyMedium?.copyWith(color: last ? c.text : c.text2)),
            ),
          ]),
        ),
      );
    }

    return SingleChildScrollView(
      key: const Key('breadcrumbs'),
      scrollDirection: Axis.horizontal,
      reverse: true,
      child: Row(children: [
        for (var i = 0; i < crumbs.length; i++) ...[
          if (i > 0) Text('/', style: tt.bodyMedium?.copyWith(color: c.text3)),
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
            final ok = await confirmDanger(context, title: '删除页面？', message: '页面中的所有内容和子页面都会被删除。');
            if (ok) {
              doc.sync.delete(page.id);
              if (context.mounted && Navigator.of(context).canPop()) Navigator.of(context).maybePop();
            }
        }
      },
      itemBuilder: (_) => [
        menuItem(context, 'sub', CupertinoIcons.doc_on_doc, '新建子页面'),
        menuItem(context, 'global', CupertinoIcons.globe, page.viewedMode == ViewedMode.global ? '改为按设备已读' : '改为全局已读'),
        const PopupMenuDivider(height: Gap.m + 1),
        menuItem(context, 'delete', CupertinoIcons.trash, '删除页面', danger: true),
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
    final c = AppColors.of(context);
    Widget b(String tip, IconData icon, VoidCallback? f, {Key? key}) => IconButton(
          key: key,
          tooltip: tip,
          icon: Icon(icon, size: Sizes.iconSm + 2),
          onPressed: f,
        );
    final divider = Padding(
      padding: const EdgeInsets.symmetric(horizontal: Gap.xs, vertical: Gap.l),
      child: SizedBox(width: 1, child: ColoredBox(color: c.separator)),
    );
    return TextFieldTapRegion(
      // 浮动胶囊工具栏（Notion 选区工具栏 + HIG 材质）：不再是贴底的灰条
      child: Material(
        type: MaterialType.transparency,
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(Gap.l, Gap.s, Gap.l, Gap.l),
            child: Center(
              child: Glass(
                key: const Key('formatToolbar'),
                radius: AppRadius.l,
                child: SizedBox(
            height: Sizes.bar,
            child: ListView(shrinkWrap: true, scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: Gap.s, vertical: Gap.s), children: [
              PopupMenuButton<DocType>(
                tooltip: '转换块类型',
                icon: const Icon(CupertinoIcons.textformat, size: Sizes.iconSm + 2),
                onSelected: (t) {
                  final id = doc.focusedId.value;
                  if (id == null) return;
                  doc.setType(id, t, text: docText(doc.sync.byId(id)!));
                },
                itemBuilder: (_) => [
                  for (final sc in slashCommands.where((sc) => sc.type != null && isTextual(sc.type!)))
                    menuItem<DocType>(context, sc.type!, sc.icon, sc.label),
                ],
              ),
              b('粗体 (Ctrl+B)', CupertinoIcons.bold, () => row()?.wrap('**'), key: const Key('tbBold')),
              b('斜体 (Ctrl+I)', CupertinoIcons.italic, () => row()?.wrap('*')),
              b('行内代码 (Ctrl+E)', CupertinoIcons.chevron_left_slash_chevron_right, () => row()?.wrap('`')),
              b('删除线 (Ctrl+Shift+S)', CupertinoIcons.strikethrough, () => row()?.wrap('~~')),
              b('链接 (Ctrl+Shift+K)', CupertinoIcons.link, () => row()?.promptLink()),
              b('打开链接', CupertinoIcons.arrow_up_right_square, () {
                final url = row()?.linkAtCaret;
                if (url != null) launchLink(url);
              }),
              divider,
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
              divider,
              b('撤销', CupertinoIcons.arrow_uturn_left, doc.canUndo ? doc.undo : null),
              b('重做', CupertinoIcons.arrow_uturn_right, doc.canRedo ? doc.redo : null),
              b('完成', CupertinoIcons.keyboard_chevron_compact_down, () => FocusManager.instance.primaryFocus?.unfocus()),
            ]),
          ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
