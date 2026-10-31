import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'desktop.dart';
import 'scope.dart';

const appVersion = '1.2.0';

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
            title: const Text('导出全部笔记'),
            subtitle: const Text('存成一个 Markdown 文件，方便自己备份'),
            onTap: () async {
              final file = await s.exportNotesFile();
              if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('已写到 ${file.path}')));
            },
          ),
          ListTile(
            title: const Text('导入 Markdown'),
            subtitle: const Text('选一个 .md，变成一篇新笔记'),
            onTap: () async {
              final picked = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['md', 'txt', 'markdown']);
              if (picked.isEmpty) return;
              final f = picked.first;
              final path = f.path;
              if (path == null) return;
              final text = await File(path).readAsString();
              final title = f.name.replaceAll(RegExp(r'\.(md|txt|markdown)$'), '');
              s.create(title: title, body: text);
              if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('已导入 $title')));
            },
          ),
          ListTile(
            title: const Text('退出登录'),
            onTap: () async {
              final ok = await showDialog<bool>(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('退出登录'),
                  content: const Text('这台设备上记住的钥匙会清掉。笔记还在服务器上，用同一个密码可以再进来。'),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
                    FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('退出')),
                  ],
                ),
              );
              if (ok != true) return;
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
