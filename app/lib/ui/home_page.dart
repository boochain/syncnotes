import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../sync/sync_client.dart';
import 'block_card.dart';
import 'quick_send_bar.dart';
import 'settings_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  bool _searching = false;
  String _filter = '';

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 16,
        title: AnimatedSwitcher(
          duration: const Duration(milliseconds: 200),
          child: _searching
              ? TextField(
                  key: const ValueKey('search'),
                  autofocus: true,
                  onChanged: (v) => setState(() => _filter = v),
                  decoration: const InputDecoration(hintText: '搜索…', border: InputBorder.none),
                )
              : Row(key: const ValueKey('title'), children: [
                  const Text('SyncNotes'),
                  const SizedBox(width: 10),
                  ListenableBuilder(listenable: s.sync, builder: (c, _) => ConnectionBadge(sync: s.sync)),
                ]),
        ),
        actions: [
          IconButton(
            tooltip: _searching ? '关闭搜索' : '搜索',
            icon: Icon(_searching ? Icons.close : Icons.search),
            onPressed: () => setState(() {
              _searching = !_searching;
              _filter = '';
            }),
          ),
          IconButton(
            tooltip: '设置',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => Navigator.of(context)
                .push(MaterialPageRoute(builder: (_) => const SettingsPage())),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async => s.sync.reconnectNow(),
        child: BlockList(filter: _filter),
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
        duration: const Duration(milliseconds: 300),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            width: 7,
            height: 7,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 5),
          Text(pending > 0 ? '$label · $pending 待同步' : label,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(color: color)),
        ]),
      ),
    );
  }
}
