import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
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
    return Scaffold(
      appBar: AppBar(
        leading: widget.onMenu == null ? null : IconButton(key: const Key('menuButton'), icon: const Icon(CupertinoIcons.sidebar_left), tooltip: '菜单', onPressed: widget.onMenu),
        titleSpacing: widget.onMenu == null ? 16 : 0,
        title: AnimatedSwitcher(
          duration: Motion.short4,
          child: _searching
              ? TextField(
                  key: const ValueKey('search'),
                  autofocus: true,
                  onChanged: (v) => setState(() => _filter = v),
                  decoration: const InputDecoration(hintText: '搜索…', border: InputBorder.none),
                )
              : Row(key: const ValueKey('title'), children: [
                  Text(widget.embedded ? '收件箱' : 'SyncNotes'),
                  const SizedBox(width: 10),
                  if (!widget.embedded) Flexible(child: ListenableBuilder(listenable: s.sync, builder: (c, _) => ConnectionBadge(sync: s.sync))),
                ]),
        ),
        actions: [
          IconButton(
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
            tooltip: '设置',
            icon: const Icon(CupertinoIcons.gear),
            onPressed: () => Navigator.of(context)
                .push(MaterialPageRoute(builder: (_) => const SettingsPage())),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async => s.sync.reconnectNow(),
        child: Column(children: [
          SizedBox(
            height: 44,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              children: [
                for (final e in _kinds.entries)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ChoiceChip(
                      key: Key('filter-${e.key}'),
                      label: Text(e.value.$1),
                      selected: _kind == e.key,
                      showCheckmark: false,
                      visualDensity: VisualDensity.compact,
                      onSelected: (_) => setState(() => _kind = e.key),
                    ),
                  ),
              ],
            ),
          ),
          Expanded(child: BlockList(filter: _filter, kinds: _kinds[_kind]!.$2)),
        ]),
      ),
      bottomNavigationBar: const QuickSendBar(),
    );
  }
}

class ConnectionBadge extends StatelessWidget {
  final SyncClient sync;
  const ConnectionBadge({super.key, required this.sync});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final (color, label) = switch (sync.state) {
      ConnState.online => (Colors.green, '在线'),
      ConnState.connecting => (Colors.orange, '连接中'),
      ConnState.authError => (cs.error, '登录失效'),
      ConnState.offline => (cs.outline, '离线'),
    };
    final pending = sync.pendingCount;
    return Tooltip(
      message: sync.lastError ?? label,
      child: AnimatedContainer(
        duration: Motion.medium2,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          AnimatedContainer(
            duration: Motion.medium2,
            width: 7,
            height: 7,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 5),
          Flexible(child: Text(pending > 0 ? '$label · $pending 待同步' : label,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(color: color))),
        ]),
      ),
    );
  }
}
