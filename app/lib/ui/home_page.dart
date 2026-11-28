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

    Widget buildSearchField({bool pill = false}) => SizedBox(
      height: pill ? 30 : 32,
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
          decoration: InputDecoration(
            hintText: '搜索笔记、消息、文件…',
            filled: !pill,
            fillColor: pill ? Colors.transparent : null,
            prefixIcon: const Icon(CupertinoIcons.search, size: 15),
            prefixIconConstraints: const BoxConstraints(
              minWidth: 30,
              minHeight: 30,
            ),
            contentPadding: EdgeInsets.symmetric(
              horizontal: Gap.m,
              vertical: pill ? 5 : 6,
            ),
            isDense: true,
            border: pill ? InputBorder.none : null,
            enabledBorder: pill ? InputBorder.none : null,
            focusedBorder: pill ? InputBorder.none : null,
          ),
        ),
      ),
    );

    ButtonStyle compactStyle(double dim) => IconButton.styleFrom(
      fixedSize: Size.square(dim),
      minimumSize: Size.square(dim),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      padding: EdgeInsets.zero,
    );

    // 软件标题居中，连接状态位于标题正下方
    final centeredTitle = MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.15,
      child: Column(
        key: const ValueKey('title'),
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'SyncNotes',
            key: const Key('homeTitle'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: tt.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
              fontSize: 15.5,
              height: 1.15,
            ),
          ),
          const SizedBox(height: 1),
          ListenableBuilder(
            listenable: s.sync,
            builder: (context, _) =>
                ConnectionBadge(sync: s.sync, compact: true),
          ),
        ],
      ),
    );

    // 顶栏：头像/菜单最左，标题与状态居中，设置（及桌面窗口缩放）最右。
    final leadingButtons = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.onMenu != null)
          IconButton(
            key: const Key('menuButton'),
            icon: Icon(
              widget.embedded
                  ? CupertinoIcons.sidebar_left
                  : CupertinoIcons.person_crop_circle_fill,
            ),
            tooltip: widget.embedded ? '展开侧边栏' : '菜单与侧边栏',
            onPressed: widget.onMenu,
          ),
      ],
    );

    final trailingButtons = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (isDesktop)
          ValueListenableBuilder<bool>(
            valueListenable: DesktopShell.instance.expanded,
            builder: (c, ex, _) => IconButton(
              tooltip: ex ? '收起为小窗' : '展开窗口',
              icon: Icon(
                ex
                    ? CupertinoIcons.arrow_down_right_arrow_up_left
                    : CupertinoIcons.arrow_up_left_arrow_down_right,
              ),
              onPressed: DesktopShell.instance.toggleExpanded,
            ),
          ),
        if (!widget.embedded)
          IconButton(
            key: const Key('homeSettings'),
            tooltip: '设置',
            icon: const Icon(CupertinoIcons.gear),
            onPressed: () =>
                Navigator.of(context).push(fadeRoute(const SettingsPage())),
          ),
      ],
    );

    final barContent = SizedBox(
      height: Sizes.bar,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Gap.xs),
        child: Row(
          children: [
            leadingButtons,
            Expanded(child: Center(child: centeredTitle)),
            trailingButtons,
          ],
        ),
      ),
    );

    // 分类行：胶囊分类、搜索，查看方式紧挨搜索右侧。
    final viewModeButton = IconButton(
      key: const Key('viewModeToggle'),
      tooltip: isGrid ? '切换为普通列表视图' : '切换为自由便签画布',
      icon: Icon(
        isGrid ? CupertinoIcons.list_bullet : CupertinoIcons.square_grid_2x2,
      ),
      onPressed: toggleViewMode,
    );
    final filterAndSearchRow = SizedBox(
      height: Sizes.bar,
      child: Row(
        children: [
          Expanded(
            child: _searching
                ? Padding(
                    padding: const EdgeInsets.only(left: Gap.l, right: Gap.xs),
                    child: buildSearchField(),
                  )
                : ListView(
                    key: const Key('filterRow'),
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(
                      horizontal: Gap.l,
                      vertical: (Sizes.bar - Sizes.compact) / 2,
                    ),
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
          ),
          IconButton(
            key: const Key('homeSearch'),
            tooltip: _searching ? '关闭搜索' : '搜索',
            icon: Icon(
              _searching ? CupertinoIcons.xmark : CupertinoIcons.search,
            ),
            onPressed: toggleSearch,
          ),
          viewModeButton,
          const SizedBox(width: Gap.xs),
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
            padding: const EdgeInsets.symmetric(
              horizontal: Gap.l,
              vertical: Gap.xs,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    s.sync.lastError ?? '服务器指纹和上次不一致',
                    style: tt.bodySmall?.copyWith(color: c.danger),
                  ),
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
              ],
            ),
          ),
        );
      },
    );

    // 悬浮液态玻璃分类胶囊（4 个切换项），搜索时平滑切换为搜索框
    Widget buildFloatingCategoryPill(double maxW) {
      return Glass(
        radius: 18,
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
        child: Material(
          type: MaterialType.transparency,
          child: MotionSwitch(
            duration: Motion.short4,
            child: _searching
                ? SizedBox(
                    key: const ValueKey('pill-search'),
                    width: (maxW - 12).clamp(160.0, 300.0),
                    child: buildSearchField(pill: true),
                  )
                : ConstrainedBox(
                    key: const Key('filterRow'),
                    constraints: BoxConstraints(
                      maxWidth: (maxW - 12).clamp(180.0, 440.0),
                    ),
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (final e in _kinds.entries)
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 2,
                              ),
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
                child: Column(
                  children: [
                    DecoratedBox(
                      decoration: BoxDecoration(
                        border: Border(bottom: BorderSide(color: c.separator)),
                      ),
                      child: barContent,
                    ),
                    filterAndSearchRow,
                    sealBanner,
                    Expanded(
                      child: RefreshIndicator(
                        onRefresh: () async => s.sync.reconnectNow(),
                        child: BlockList(
                          filter: _filter,
                          kinds: _kinds[_kind]!.$2,
                          gridMode: isGrid,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              bottomNavigationBar: const QuickSendBar(),
            );
          }

          // 液态玻璃悬浮架构：
          // 1. 顶栏：头像最左，标题与状态居中，设置最右（桌面窗口缩放挨着设置）；
          // 2. 第二行：分类胶囊、搜索、查看方式（查看方式在搜索右侧）；
          // 3. 底部栏：常驻消息发送框 + 右侧独立圆形新建按钮。
          return LayoutBuilder(
            builder: (context, constraints) {
              final mediaPad = MediaQuery.paddingOf(context);
              final topInset =
                  mediaPad.top + 102.0 + (s.sync.sealBlocked ? 48.0 : 0.0);
              final bottomInset = mediaPad.bottom + 78.0;
              final hPad = constraints.maxWidth >= 660 ? Gap.xl : Gap.m;
              final iconDim = constraints.maxWidth < 460 ? 30.0 : 32.0;
              final iconStyle = compactStyle(iconDim);

              Widget glassIconButton({
                required Key? key,
                required String tooltip,
                required IconData icon,
                required VoidCallback onPressed,
                double iconSize = 16.5,
                Color? iconColor,
              }) {
                return Glass(
                  radius: 18,
                  padding: const EdgeInsets.all(2),
                  child: Material(
                    type: MaterialType.transparency,
                    child: IconButton(
                      key: key,
                      style: iconStyle,
                      tooltip: tooltip,
                      icon: Icon(
                        icon,
                        size: iconSize,
                        color: iconColor ?? c.text2,
                      ),
                      onPressed: onPressed,
                    ),
                  ),
                );
              }

              final avatarButton = widget.onMenu == null
                  ? null
                  : glassIconButton(
                      key: const Key('menuButton'),
                      tooltip: widget.embedded ? '展开侧边栏' : '菜单与侧边栏',
                      icon: widget.embedded
                          ? CupertinoIcons.sidebar_left
                          : CupertinoIcons.person_crop_circle_fill,
                      iconSize: widget.embedded ? 17 : 20,
                      onPressed: widget.onMenu!,
                    );

              final settingsButton = widget.embedded
                  ? null
                  : glassIconButton(
                      key: const Key('homeSettings'),
                      tooltip: '设置',
                      icon: CupertinoIcons.gear,
                      onPressed: () => Navigator.of(
                        context,
                      ).push(fadeRoute(const SettingsPage())),
                    );

              final expandButton = !isDesktop
                  ? null
                  : ValueListenableBuilder<bool>(
                      valueListenable: DesktopShell.instance.expanded,
                      builder: (ctx, ex, _) => glassIconButton(
                        key: null,
                        tooltip: ex ? '收起为小窗' : '展开窗口',
                        icon: ex
                            ? CupertinoIcons.arrow_down_right_arrow_up_left
                            : CupertinoIcons.arrow_up_left_arrow_down_right,
                        iconSize: 15.5,
                        iconColor: AppColors.of(ctx).text2,
                        onPressed: DesktopShell.instance.toggleExpanded,
                      ),
                    );

              final searchCircleButton = glassIconButton(
                key: const Key('homeSearch'),
                tooltip: _searching ? '关闭搜索' : '搜索',
                icon: _searching ? CupertinoIcons.xmark : CupertinoIcons.search,
                iconSize: 16,
                onPressed: toggleSearch,
              );

              final viewModeButton = glassIconButton(
                key: const Key('viewModeToggle'),
                tooltip: isGrid ? '切换为普通列表视图' : '切换为自由便签画布',
                icon: isGrid
                    ? CupertinoIcons.list_bullet
                    : CupertinoIcons.square_grid_2x2,
                onPressed: toggleViewMode,
              );

              final trailingCluster = Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (expandButton != null) ...[
                    expandButton,
                    const SizedBox(width: 6),
                  ],
                  ?settingsButton,
                ],
              );

              final floatingTopBar = SafeArea(
                bottom: false,
                child: Padding(
                  padding: EdgeInsets.fromLTRB(hPad, Gap.s, hPad, Gap.xs),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        height: 40,
                        child: Row(
                          children: [
                            if (avatarButton != null)
                              avatarButton
                            else
                              const SizedBox(width: 36),
                            Expanded(child: Center(child: centeredTitle)),
                            if (trailingCluster.children.isNotEmpty)
                              trailingCluster
                            else
                              const SizedBox(width: 36),
                          ],
                        ),
                      ),
                      const SizedBox(height: 6),
                      Center(
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            buildFloatingCategoryPill(
                              constraints.maxWidth - 120,
                            ),
                            const SizedBox(width: 8),
                            searchCircleButton,
                            const SizedBox(width: 6),
                            viewModeButton,
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
                    const Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: QuickSendBar(floating: true),
                    ),
                  ],
                ),
              );
            },
          );
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
  const FilterTab({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });
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
        ? (dark
              ? Colors.white.withValues(alpha: 0.18)
              : Colors.white.withValues(alpha: 0.88))
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
            padding: const EdgeInsets.symmetric(horizontal: 12),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: widget.selected
                  ? selectedBg
                  : (_hover ? c.hover : Colors.transparent),
              borderRadius: BorderRadius.circular(15),
              border: widget.selected
                  ? Border.all(
                      color: dark
                          ? Colors.white.withValues(alpha: 0.24)
                          : Colors.white.withValues(alpha: 0.92),
                    )
                  : null,
              boxShadow: widget.selected && Glass.surfaceTranslucent
                  ? [
                      BoxShadow(
                        color: Colors.black.withValues(
                          alpha: dark ? 0.25 : 0.06,
                        ),
                        blurRadius: 8,
                        offset: const Offset(0, 2),
                      ),
                    ]
                  : const [],
            ),
            child: Text(
              widget.label,
              maxLines: 1,
              style: (widget.selected ? tt.labelLarge : tt.bodyMedium)
                  ?.copyWith(
                    fontSize: 13,
                    fontWeight: widget.selected
                        ? FontWeight.w600
                        : FontWeight.w500,
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

  /// 只显示 8px 圆点（侧边栏用）；完整状态在提示里
  final bool dotOnly;

  /// 紧凑标题下方模式：始终显示 7px 圆点 + 精简状态文字（在线 / 连接中 / 离线）
  final bool compact;
  const ConnectionBadge({
    super.key,
    required this.sync,
    this.dotOnly = false,
    this.compact = false,
  });

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
    final dotSize = compact ? 7.0 : 8.0;
    final dot = AnimatedContainer(
      key: const Key('connDot'),
      duration: Motion.medium2,
      width: dotSize,
      height: dotSize,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
    return Tooltip(
      message: sync.lastError ?? text,
      child: Semantics(
        label: '连接状态：$text',
        child: compact
            ? Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  dot,
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(
                      text,
                      key: const Key('connLabel'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        fontSize: 10.5,
                        height: 1.1,
                        color: c.text3,
                      ),
                    ),
                  ),
                ],
              )
            : dotOnly
            ? Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox.square(dimension: 16, child: Center(child: dot)),
                  if (sync.state != ConnState.online || pending > 0)
                    Flexible(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 120),
                        child: Text(
                          text,
                          key: const Key('connLabel'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(
                            context,
                          ).textTheme.bodySmall?.copyWith(color: c.text3),
                        ),
                      ),
                    ),
                ],
              )
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  dot,
                  const SizedBox(width: Gap.s),
                  Flexible(
                    child: Text(
                      text,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}
