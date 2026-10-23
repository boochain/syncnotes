import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'ds.dart';
import 'tokens.dart';

import '../app_scope.dart';
import '../models/block.dart';
import '../platform/desktop.dart';
import '../sync/sync_client.dart';
import 'block_card.dart';
import 'quick_send_bar.dart';
import 'settings_page.dart';

class HomePage extends StatefulWidget {
  /// 窄屏：打开侧边抽屉
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
    // 顶栏 44：左右按钮都是 32×32，标题 16/600，全部垂直居中
    final bar = Container(
      height: Sizes.bar,
      padding: const EdgeInsets.symmetric(horizontal: Gap.s),
      decoration: BoxDecoration(color: c.bg, border: Border(bottom: BorderSide(color: c.separator))),
      child: Row(children: [
        if (widget.onMenu != null)
          IconButton(key: const Key('menuButton'), icon: const Icon(CupertinoIcons.sidebar_left), tooltip: '菜单', onPressed: widget.onMenu)
        else
          const SizedBox(width: Gap.s),
        const SizedBox(width: Gap.xs),
        Expanded(
          child: _searching
              ? SizedBox(
                  height: Sizes.control,
                  // Esc 关闭搜索（桌面）
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
                    style: tt.bodyMedium,
                    onChanged: (v) => setState(() => _filter = v),
                    decoration: const InputDecoration(
                      hintText: '搜索…',
                      prefixIcon: Icon(CupertinoIcons.search, size: Sizes.iconSm),
                      prefixIconConstraints: BoxConstraints(minWidth: Sizes.control, minHeight: Sizes.control),
                      contentPadding: EdgeInsets.symmetric(horizontal: Gap.m, vertical: (Sizes.control - 20) / 2),
                    ),
                  ),
                  ),
                )
              : Row(key: const ValueKey('title'), children: [
                  Flexible(
                    child: Text(widget.embedded ? '收件箱' : 'SyncNotes',
                        key: const Key('homeTitle'), maxLines: 1, overflow: TextOverflow.ellipsis, style: tt.titleMedium),
                  ),
                  if (!widget.embedded) ...[
                    const SizedBox(width: Gap.m),
                    // 窄屏 + 触屏 48dp 按钮时，状态文字可以被压缩（省略号），不溢出
                    Flexible(child: ListenableBuilder(listenable: s.sync, builder: (c, _) => ConnectionBadge(sync: s.sync, dotOnly: true))),
                  ],
                ]),
        ),
        const SizedBox(width: Gap.xs),
        IconButton(
          key: const Key('homeSearch'),
          tooltip: _searching ? '关闭搜索' : '搜索',
          icon: Icon(_searching ? CupertinoIcons.xmark : CupertinoIcons.search),
          onPressed: () => setState(() {
            _searching = !_searching;
            _filter = '';
          }),
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
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SettingsPage())),
          ),
      ]),
    );
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
      child: Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(children: [
          bar,
          // 筛选行 44：标签 28 高、垂直居中
          SizedBox(
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
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () async => s.sync.reconnectNow(),
              child: BlockList(filter: _filter, kinds: _kinds[_kind]!.$2),
            ),
          ),
        ]),
      ),
      bottomNavigationBar: const QuickSendBar(),
    ),
    );
  }
}

/// 筛选标签（Notion 视图标签样式）：高 28，圆角 6，选中为中性灰底 + 500 字重
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
    return Semantics(
      button: true,
      selected: widget.selected,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (e) { if (isMouseHover(e)) setState(() => _hover = true); },
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: Motion.short2,
            height: Sizes.compact,
            padding: const EdgeInsets.symmetric(horizontal: Gap.m + 2),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: widget.selected ? c.selected : (_hover ? c.hover : Colors.transparent),
              borderRadius: BorderRadius.circular(AppRadius.s),
            ),
            child: Text(widget.label,
                maxLines: 1,
                style: (widget.selected ? tt.labelLarge : tt.bodyMedium)?.copyWith(color: widget.selected ? c.text : c.text2)),
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
                // 在线且没有待同步时只显示圆点；其余状态把文字也露出来（离线 / 待同步一眼可见）
                if (sync.state != ConnState.online || pending > 0)
                  Flexible(child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 120),
                    child: Text(text,
                        key: const Key('connLabel'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(color: c.text3)),
                  )),
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
