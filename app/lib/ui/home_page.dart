import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_scope.dart';
import '../models/block.dart';
import '../platform/desktop.dart';
import '../sync/sync_client.dart';
import '../sync/wire_seal.dart';
import 'block_card.dart';
import 'ds.dart';
import 'glass.dart';
import 'motion.dart';
import 'quick_send_bar.dart';
import 'settings_page.dart';
import 'tokens.dart';

class HomePage extends StatefulWidget {
  /// 窄屏打开侧边抽屉，或宽屏展开已折叠的侧边栏
  final VoidCallback? onMenu;

  /// 宽屏嵌入外壳时隐藏设置按钮（侧边栏里有）
  final bool embedded;
  const HomePage({super.key, this.onMenu, this.embedded = false});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  bool _searching = false;
  String _filter = '';
  String _kind = 'all';

  static const _kinds = <String, (String, Set<BlockKind>?)>{
    'all': ('全部', null),
    'msg': ('消息', {BlockKind.message}),
    'page': ('页面', {BlockKind.page, BlockKind.note}),
    'file': ('文件', {BlockKind.file, BlockKind.folder}),
  };

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final c = AppColors.of(context);
    final tt = Theme.of(context).textTheme;
    final isGrid = Glass.useShader ? s.settings.inboxViewMode != 'list' : false;

    void toggleViewMode() {
      final next = isGrid ? 'list' : 'grid';
      s.settings.inboxViewMode = next;
      setState(() {});
    }

    void toggleSearch() {
      setState(() {
        _searching = !_searching;
        _filter = '';
      });
    }

    final searchField = SizedBox(
      height: 32,
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): () => setState(() {
                _searching = false;
                _filter = '';
              }),
        },
        child: TextField(
          key: const ValueKey('search'),
          autofocus: true,
          style: tt.bodyMedium?.copyWith(fontSize: 13.5),
          onChanged: (v) => setState(() => _filter = v),
          decoration: const InputDecoration(
            hintText: '搜索笔记、消息、文件…',
            prefixIcon: Icon(CupertinoIcons.search, size: 15),
            prefixIconConstraints: BoxConstraints(minWidth: 32, minHeight: 32),
            contentPadding: EdgeInsets.symmetric(horizontal: Gap.m, vertical: 6),
            isDense: true,
          ),
        ),
      ),
    );

    final compactIconStyle = IconButton.styleFrom(
      fixedSize: const Size.square(34),
      minimumSize: const Size.square(34),
      padding: EdgeInsets.zero,
    );

    final barContent = Container(
      height: Sizes.bar,
      padding: const EdgeInsets.symmetric(horizontal: Gap.s),
      child: Row(children: [
        if (widget.onMenu != null)
          IconButton(key: const Key('menuButton'), icon: const Icon(CupertinoIcons.sidebar_left), tooltip: '菜单', onPressed: widget.onMenu)
        else
          const SizedBox(width: Gap.s),
        const SizedBox(width: Gap.xs),
        Expanded(
          child: _searching
              ? searchField
              : Row(key: const ValueKey('title'), children: [
                  Flexible(
                    child: Text(widget.embedded ? '收件箱' : 'SyncNotes',
                        key: const Key('homeTitle'), maxLines: 1, overflow: TextOverflow.ellipsis, style: tt.titleMedium),
                  ),
                  if (!widget.embedded) ...[
                    const SizedBox(width: Gap.m),
                    Flexible(child: ListenableBuilder(listenable: s.sync, builder: (c, _) => ConnectionBadge(sync: s.sync, dotOnly: true))),
                  ],
                ]),
        ),
        const SizedBox(width: Gap.xs),
        IconButton(
          key: const Key('viewModeToggle'),
          tooltip: isGrid ? '切换为普通列表视图' : '切换为自由便签画布',
          icon: Icon(isGrid ? CupertinoIcons.list_bullet : CupertinoIcons.square_grid_2x2),
          onPressed: toggleViewMode,
        ),
        IconButton(
          key: const Key('homeSearch'),
          tooltip: _searching ? '关闭搜索' : '搜索',
          icon: Icon(_searching ? CupertinoIcons.xmark : CupertinoIcons.search),
          onPressed: toggleSearch,
        ),
        if (isDesktop)
          ValueListenableBuilder<bool>(
            valueListenable: DesktopShell.instance.expanded,
            builder: (c, ex, _) => IconButton(
              tooltip: ex ? '收起为小窗' : '展开窗口',
              icon: Icon(ex ? CupertinoIcons.arrow_down_right_arrow_up_left : CupertinoIcons.arrow_up_left_arrow_down_right),
              onPressed: DesktopShell.instance.toggleExpanded,
            ),
          ),
        if (!widget.embedded)
          IconButton(
            key: const Key('homeSettings'),
            tooltip: '设置',
            icon: const Icon(CupertinoIcons.gear),
            onPressed: () => Navigator.of(context).push(fadeRoute(const SettingsPage())),
          ),
      ]),
    );

    final filterRow = SizedBox(
      height: Sizes.bar,
      child: ListView(
        key: const Key('filterRow'),
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: Gap.l, vertical: (Sizes.bar - Sizes.compact) / 2),
        children: [
          for (final e in _kinds.entries)
            Padding(
              padding: const EdgeInsets.only(right: Gap.xs),
              child: FilterTab(
                key: Key('filter-${e.key}'),
                label: e.value.$1,
                selected: _kind == e.key,
                onTap: () => setState(() => _kind = e.key),
              ),
            ),
        ],
      ),
    );

    final sealBanner = ListenableBuilder(
      listenable: s.sync,
      builder: (context, _) {
        if (!s.sync.sealBlocked) return const SizedBox.shrink();
        return Material(
          color: c.danger.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(AppRadius.m),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: Gap.l, vertical: Gap.xs),
            child: Row(children: [
              Expanded(
                child: Text(s.sync.lastError ?? '服务器指纹和上次不一致', style: tt.bodySmall?.copyWith(color: c.danger)),
              ),
              TextButton(
                key: const Key('trustFingerprintHome'),
                onPressed: () {
                  final server = s.settings.server;
                  if (server != null) {
                    s.settings.clearSealPin(server);
                    WireSeal.forget(server);
                  }
                  s.sync.reconnectNow();
                },
                child: const Text('改用新指纹'),
              ),
            ]),
          ),
        );
      },
    );

    // 概念图同款悬浮液态玻璃分类胶囊（电脑端与手机端共用统一美学，搜索时帧模糊平滑变形）
    Widget buildFloatingCategoryPill(double maxW) {
      return Glass(
        radius: 21,
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
        child: Material(
          type: MaterialType.transparency,
          child: MotionSwitch(
            duration: Motion.short4,
            maxBlur: 6.0,
            child: _searching
                ? SizedBox(
                    key: const ValueKey('pill-search'),
                    width: (maxW - 32).clamp(180.0, 268.0),
                    child: searchField,
                  )
                : ConstrainedBox(
                    key: const Key('filterRow'),
                    constraints: BoxConstraints(maxWidth: (maxW - 24).clamp(200.0, 460.0)),
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (final e in _kinds.entries)
                            Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 2),
                              child: FilterTab(
                                key: Key('filter-${e.key}'),
                                label: e.value.$1,
                                selected: _kind == e.key,
                                onTap: () => setState(() => _kind = e.key),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
          ),
        ),
      );
    }

    // 返回键先关闭搜索、恢复“全部”筛选，再交给外壳（退出 / 回到收件箱）
    final transient = _searching || _kind != 'all';
    return PopScope(
      canPop: !transient,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        setState(() {
          if (_searching) {
            _searching = false;
            _filter = '';
          } else {
            _kind = 'all';
          }
        });
      },
      child: ListenableBuilder(
        listenable: Glass.backdropListenable,
        builder: (context, _) {
          final translucent = Glass.surfaceTranslucent;
          if (!translucent) {
            return Scaffold(
              backgroundColor: Glass.scaffoldBg(context),
              body: SafeArea(
                bottom: false,
                child: Column(children: [
                  DecoratedBox(
                    decoration: BoxDecoration(border: Border(bottom: BorderSide(color: c.separator))),
                    child: barContent,
                  ),
                  filterRow,
                  sealBanner,
                  Expanded(
                    child: RefreshIndicator(
                      onRefresh: () async => s.sync.reconnectNow(),
                      child: BlockList(filter: _filter, kinds: _kinds[_kind]!.$2, gridMode: isGrid),
                    ),
                  ),
                ]),
              ),
              bottomNavigationBar: const QuickSendBar(),
            );
          }

          // Apple macOS Tahoe / iOS 26 悬浮液态玻璃架构：
          // 电脑宽屏：居中悬浮液态玻璃分类胶囊 + 右侧悬浮快捷胶囊；
          // 手机窄屏：顶部通透标题行（左头像抽屉 + 中 SyncNotes + 右操作）+ 下方居中悬浮液态玻璃分类胶囊（完全对齐概念图 iPhone 视图）。
          return LayoutBuilder(builder: (context, constraints) {
            final wideHeader = constraints.maxWidth >= 660;
            final mediaPad = MediaQuery.paddingOf(context);
            final topInset = mediaPad.top + (wideHeader ? 68.0 : 102.0) + (s.sync.sealBlocked ? 48.0 : 0.0);
            final bottomInset = mediaPad.bottom + 76.0;

            final Widget floatingTopBar;
            if (wideHeader) {
              floatingTopBar = SafeArea(
                bottom: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(Gap.xl, Gap.m, Gap.xl, Gap.xs),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        height: 44,
                        child: Row(
                          children: [
                            // 左侧：展开侧边栏按钮（折叠时）+ 标题
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (widget.onMenu != null)
                                  Glass(
                                    radius: 19,
                                    padding: const EdgeInsets.all(2),
                                    child: IconButton(
                                      key: const Key('menuButton'),
                                      style: compactIconStyle,
                                      icon: const Icon(CupertinoIcons.sidebar_left, size: 17),
                                      tooltip: '展开侧边栏',
                                      onPressed: widget.onMenu,
                                    ),
                                  ),
                                if (widget.onMenu != null) const SizedBox(width: Gap.m),
                                Text(
                                  widget.embedded ? '收件箱' : 'SyncNotes',
                                  key: const Key('homeTitle'),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w600, fontSize: 16),
                                ),
                                if (!widget.embedded) ...[
                                  const SizedBox(width: Gap.s),
                                  ListenableBuilder(
                                    listenable: s.sync,
                                    builder: (c, _) => ConnectionBadge(sync: s.sync, dotOnly: true),
                                  ),
                                ],
                              ],
                            ),
                            const Spacer(),
                            // 正中：悬浮液态玻璃分类胶囊
                            buildFloatingCategoryPill(constraints.maxWidth * 0.52),
                            const Spacer(),
                            // 右侧：悬浮液态玻璃快捷操作胶囊（自由便签/列表切换、搜索、窗口展开）
                            Glass(
                              radius: 21,
                              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
                              child: Material(
                                type: MaterialType.transparency,
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    IconButton(
                                      key: const Key('viewModeToggle'),
                                      style: compactIconStyle,
                                      tooltip: isGrid ? '切换为普通列表视图' : '切换为自由便签画布',
                                      icon: Icon(
                                        isGrid ? CupertinoIcons.list_bullet : CupertinoIcons.square_grid_2x2,
                                        size: 17,
                                      ),
                                      onPressed: toggleViewMode,
                                    ),
                                    IconButton(
                                      key: const Key('homeSearch'),
                                      style: compactIconStyle,
                                      tooltip: _searching ? '关闭搜索' : '搜索',
                                      icon: Icon(_searching ? CupertinoIcons.xmark : CupertinoIcons.search, size: 17),
                                      onPressed: toggleSearch,
                                    ),
                                    if (isDesktop)
                                      ValueListenableBuilder<bool>(
                                        valueListenable: DesktopShell.instance.expanded,
                                        builder: (c, ex, _) => IconButton(
                                          style: compactIconStyle,
                                          tooltip: ex ? '收起为小窗' : '展开窗口',
                                          icon: Icon(
                                            ex
                                                ? CupertinoIcons.arrow_down_right_arrow_up_left
                                                : CupertinoIcons.arrow_up_left_arrow_down_right,
                                            size: 16,
                                          ),
                                          onPressed: DesktopShell.instance.toggleExpanded,
                                        ),
                                      ),
                                    if (!widget.embedded)
                                      IconButton(
                                        key: const Key('homeSettings'),
                                        style: compactIconStyle,
                                        tooltip: '设置',
                                        icon: const Icon(CupertinoIcons.gear, size: 17),
                                        onPressed: () => Navigator.of(context).push(fadeRoute(const SettingsPage())),
                                      ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (s.sync.sealBlocked) ...[
                        const SizedBox(height: Gap.xs),
                        sealBanner,
                      ],
                    ],
                  ),
                ),
              );
            } else {
              // 手机端/窄屏：1:1 对齐概念图 iOS 26 悬浮结构（顶部通透三段标题行 + 下方居中悬浮液态玻璃分类胶囊）
              floatingTopBar = SafeArea(
                bottom: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(Gap.m, Gap.xs, Gap.m, Gap.xs),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        height: 40,
                        child: Row(
                          children: [
                            if (widget.onMenu != null)
                              IconButton(
                                key: const Key('menuButton'),
                                style: compactIconStyle,
                                icon: Icon(CupertinoIcons.person_crop_circle_fill, size: 24, color: c.text2),
                                tooltip: '菜单与侧边栏',
                                onPressed: widget.onMenu,
                              )
                            else
                              const SizedBox(width: 34),
                            Expanded(
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Flexible(
                                    child: Text(
                                      widget.embedded ? '收件箱' : 'SyncNotes',
                                      key: const Key('homeTitle'),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w600, fontSize: 16.5),
                                    ),
                                  ),
                                  if (!widget.embedded) ...[
                                    const SizedBox(width: 6),
                                    ListenableBuilder(
                                      listenable: s.sync,
                                      builder: (c, _) => ConnectionBadge(sync: s.sync, dotOnly: true),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  key: const Key('viewModeToggle'),
                                  style: compactIconStyle,
                                  tooltip: isGrid ? '切换为普通列表视图' : '切换为便签卡片视图',
                                  icon: Icon(
                                    isGrid ? CupertinoIcons.list_bullet : CupertinoIcons.square_grid_2x2,
                                    size: 18,
                                    color: c.text2,
                                  ),
                                  onPressed: toggleViewMode,
                                ),
                                if (!widget.embedded)
                                  IconButton(
                                    key: const Key('homeSettings'),
                                    style: compactIconStyle,
                                    tooltip: '设置',
                                    icon: Icon(CupertinoIcons.gear, size: 18, color: c.text2),
                                    onPressed: () => Navigator.of(context).push(fadeRoute(const SettingsPage())),
                                  ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 6),
                      // 手机端居中悬浮液态玻璃分类胶囊（与电脑端统一风格）
                      Center(child: buildFloatingCategoryPill(constraints.maxWidth)),
                      if (s.sync.sealBlocked) ...[
                        const SizedBox(height: Gap.xs),
                        sealBanner,
                      ],
                    ],
                  ),
                ),
              );
            }

            return Scaffold(
              backgroundColor: Colors.transparent,
              body: Stack(
                children: [
                  Positioned.fill(
                    child: RefreshIndicator(
                      edgeOffset: topInset,
                      onRefresh: () async => s.sync.reconnectNow(),
                      child: BlockList(
                        filter: _filter,
                        kinds: _kinds[_kind]!.$2,
                        gridMode: isGrid,
                        topPadding: topInset,
                        bottomPadding: bottomInset,
                      ),
                    ),
                  ),
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    child: floatingTopBar,
                  ),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: QuickSendBar(floating: true, onSearch: toggleSearch),
                  ),
                ],
              ),
            );
          });
        },
      ),
    );
  }
}

/// 筛选标签（Apple 悬浮胶囊分段样式）：高 30，圆角胶囊，选中为通透强调底 + 600 字重
class FilterTab extends StatefulWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const FilterTab({super.key, required this.label, required this.selected, required this.onTap});
  @override
  State<FilterTab> createState() => _FilterTabState();
}

class _FilterTabState extends State<FilterTab> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final tt = Theme.of(context).textTheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final selectedBg = Glass.surfaceTranslucent
        ? (dark ? Colors.white.withValues(alpha: 0.18) : Colors.white.withValues(alpha: 0.88))
        : c.selected;
    return Semantics(
      button: true,
      selected: widget.selected,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (e) {
          if (isMouseHover(e)) setState(() => _hover = true);
        },
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: Motion.short2,
            curve: Curves.easeOutCubic,
            height: Glass.surfaceTranslucent ? 30 : Sizes.compact,
            padding: const EdgeInsets.symmetric(horizontal: 13),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: widget.selected ? selectedBg : (_hover ? c.hover : Colors.transparent),
              borderRadius: BorderRadius.circular(15),
              border: widget.selected
                  ? Border.all(color: dark ? Colors.white.withValues(alpha: 0.24) : Colors.white.withValues(alpha: 0.92))
                  : null,
              boxShadow: widget.selected && Glass.surfaceTranslucent
                  ? [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: dark ? 0.25 : 0.06),
                        blurRadius: 8,
                        offset: const Offset(0, 2),
                      ),
                    ]
                  : const [],
            ),
            child: Text(
              widget.label,
              maxLines: 1,
              style: (widget.selected ? tt.labelLarge : tt.bodyMedium)?.copyWith(
                fontSize: 13,
                fontWeight: widget.selected ? FontWeight.w600 : FontWeight.w500,
                color: widget.selected ? c.text : c.text2,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class ConnectionBadge extends StatelessWidget {
  final SyncClient sync;

  /// 只显示 8px 圆点（顶栏 / 侧边栏用）；完整状态在提示里
  final bool dotOnly;
  const ConnectionBadge({super.key, required this.sync, this.dotOnly = false});

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final (color, label) = sync.sealBlocked
        ? (c.danger, '已拒绝')
        : switch (sync.state) {
            ConnState.online => (c.success, '在线'),
            ConnState.connecting => (c.warning, '连接中'),
            ConnState.authError => (c.danger, '登录失效'),
            ConnState.offline => (c.text3, '离线'),
          };
    final pending = sync.pendingCount;
    final text = pending > 0 ? '$label · $pending 待同步' : label;
    final dot = AnimatedContainer(
      key: const Key('connDot'),
      duration: Motion.medium2,
      width: 8,
      height: 8,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
    return Tooltip(
      message: sync.lastError ?? text,
      child: Semantics(
        label: '连接状态：$text',
        child: dotOnly
            ? Row(mainAxisSize: MainAxisSize.min, children: [
                SizedBox.square(dimension: 16, child: Center(child: dot)),
                if (sync.state != ConnState.online || pending > 0)
                  Flexible(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 120),
                      child: Text(text,
                          key: const Key('connLabel'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: c.text3)),
                    ),
                  ),
              ])
            : Row(mainAxisSize: MainAxisSize.min, children: [
                dot,
                const SizedBox(width: Gap.s),
                Flexible(
                  child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodySmall),
                ),
              ]),
      ),
    );
  }
}
