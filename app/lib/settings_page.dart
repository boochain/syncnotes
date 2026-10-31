import 'package:flutter/material.dart';

import 'desktop.dart';
import 'scope.dart';

const appVersion = '1.1.0';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final s = Scope.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        children: [
          ListTile(title: const Text('服务器'), subtitle: Text(s.server ?? '')),
          ListTile(title: const Text('用户'), subtitle: Text(s.username ?? '')),
          if (s.knownServers.isNotEmpty) const ListTile(title: Text('记住的服务器')),
          for (final host in s.knownServers)
            ListTile(
              title: Text(host),
              trailing: IconButton(tooltip: '删除', onPressed: () => s.forgetServer(host), icon: const Icon(Icons.close)),
              onTap: () => s.rememberServer(host),
            ),
          const ListTile(title: Text('外观')),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'system', label: Text('系统')),
                ButtonSegment(value: 'light', label: Text('浅色')),
                ButtonSegment(value: 'dark', label: Text('深色')),
              ],
              selected: {s.themeMode},
              onSelectionChanged: (v) => s.themeMode = v.first,
            ),
          ),
          const SizedBox(height: 12),
          if (isDesktop)
            ListTile(
              title: Text(s.windowExpanded ? '收起为小窗' : '展开窗口'),
              onTap: () async {
                final next = !s.windowExpanded;
                s.windowExpanded = next;
                await Desk.toggle(next);
              },
            ),
          ListTile(
            title: const Text('退出登录'),
            onTap: () async {
              await s.logout();
              if (context.mounted) Navigator.of(context).popUntil((r) => r.isFirst);
            },
          ),
          const ListTile(title: Text('版本'), subtitle: Text(appVersion)),
          const ListTile(
            title: Text('加密'),
            subtitle: Text('笔记和文件用你的密码加密后才发出去。文件夹、标签、置顶和回收站都在这篇密文里，换设备登录同一个账号就能看到。'),
          ),
        ],
      ),
    );
  }
}
