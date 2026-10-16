import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../platform/android_service.dart';
import '../platform/desktop.dart';
import '../sync/sync_client.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  bool? _autoStart;

  @override
  void initState() {
    super.initState();
    _loadAutoStart();
  }

  Future<void> _loadAutoStart() async {
    bool v;
    try {
      v = isDesktop ? await DesktopShell.isAutoStartEnabled() : false;
    } catch (_) {
      v = false;
    }
    if (!mounted) return;
    setState(() => _autoStart = isDesktop ? v : AppScope.of(context).settings.autoStart);
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final st = s.settings;
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      // HIG 设置页：内容限宽居中，宽屏下开关不至于离标签太远
      body: Align(alignment: Alignment.topCenter, child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 680), child: ListView(padding: const EdgeInsets.only(bottom: 24), children: [
        _section(context, '账号'),
        ListTile(
          leading: const Icon(CupertinoIcons.person),
          title: Text(st.username ?? ''),
          subtitle: Text(st.server ?? ''),
        ),
        ListenableBuilder(
          listenable: s.sync,
          builder: (c, _) => ListTile(
            leading: const Icon(CupertinoIcons.arrow_2_circlepath),
            title: Text(switch (s.sync.state) {
              ConnState.online => '已连接',
              ConnState.connecting => '连接中…',
              ConnState.authError => '登录已失效，请重新登录',
              ConnState.offline => '离线（将自动重连）',
            }),
            subtitle: Text('同步序号 ${s.sync.lastSeq} · 待发送 ${s.sync.pendingCount} · 设备 ${st.deviceId.length > 8 ? st.deviceId.substring(0, 8) : st.deviceId}'),
            trailing: TextButton(onPressed: s.sync.reconnectNow, child: const Text('重连')),
          ),
        ),
        _section(context, '外观'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: ValueListenableBuilder<ThemeMode>(
            valueListenable: s.themeMode,
            builder: (c, mode, _) => SegmentedButton<ThemeMode>(
              key: const Key('themeSelector'),
              segments: const [
                ButtonSegment(value: ThemeMode.system, icon: Icon(CupertinoIcons.circle_lefthalf_fill), label: Text('跟随系统')),
                ButtonSegment(value: ThemeMode.light, icon: Icon(CupertinoIcons.sun_max), label: Text('浅色')),
                ButtonSegment(value: ThemeMode.dark, icon: Icon(CupertinoIcons.moon), label: Text('深色')),
              ],
              selected: {mode},
              onSelectionChanged: (v) {
                s.themeMode.value = v.first;
                st.themeMode = v.first.name;
              },
            ),
          ),
        ),
        _section(context, '启动'),
        SwitchListTile(
          secondary: const Icon(CupertinoIcons.power),
          title: Text(Platform.isAndroid ? '开机自动启动后台同步' : '登录系统时自动启动'),
          value: _autoStart ?? false,
          onChanged: _autoStart == null
              ? null
              : (v) async {
                  st.autoStart = v;
                  if (isDesktop) {
                    await DesktopShell.setAutoStart(v);
                  } else if (Platform.isAndroid) {
                    AndroidSyncService.init(autoRunOnBoot: v);
                    // 开机自启依赖前台服务：开启自启时一并开启后台连接
                    if (v && !st.foregroundService) {
                      st.foregroundService = true;
                    }
                    if (v) await AndroidSyncService.start();
                  }
                  setState(() => _autoStart = v);
                },
        ),
        if (isDesktop)
          SwitchListTile(
            secondary: const Icon(CupertinoIcons.eye_slash),
            title: const Text('启动时最小化到托盘'),
            value: st.startMinimized,
            onChanged: (v) => setState(() => st.startMinimized = v),
          ),
        if (Platform.isAndroid)
          SwitchListTile(
            secondary: const Icon(Icons.notifications_active_outlined),
            title: const Text('后台保持连接（前台服务）'),
            subtitle: const Text('常驻通知栏，保证及时收到新消息推送'),
            value: st.foregroundService,
            onChanged: (v) async {
              setState(() => st.foregroundService = v);
              v ? await AndroidSyncService.start() : await AndroidSyncService.stop();
            },
          ),
        _section(context, '通知与已读'),
        SwitchListTile(
          secondary: const Icon(CupertinoIcons.bell),
          title: const Text('新内容通知'),
          value: st.notifications,
          onChanged: (v) => setState(() => st.notifications = v),
        ),
        SwitchListTile(
          secondary: const Icon(CupertinoIcons.globe),
          title: const Text('新建块默认使用全局已读'),
          subtitle: Text(st.defaultGlobalViewed
              ? '在一台设备上查看后，所有设备都标为已读'
              : '每台设备独立记录已读状态（可在每个块上单独切换）'),
          value: st.defaultGlobalViewed,
          onChanged: (v) => setState(() => st.defaultGlobalViewed = v),
        ),
        _section(context, '其他'),
        ListTile(
          leading: const Icon(CupertinoIcons.clear),
          title: const Text('清除本地缓存并重新同步'),
          onTap: () async {
            await s.sync.clearLocal(keepPending: true);
            s.sync.reconnectNow();
          },
        ),
        ListTile(
          leading: Icon(CupertinoIcons.square_arrow_right, color: Theme.of(context).colorScheme.error),
          title: Text('退出登录', style: TextStyle(color: Theme.of(context).colorScheme.error)),
          onTap: () async {
            final pending = s.sync.pendingCount;
            final ok = await showDialog<bool>(
              context: context,
              builder: (c) => AlertDialog(
                title: const Text('退出登录？'),
                content: Text(pending > 0
                    ? '还有 $pending 条修改尚未同步到服务器，退出后将丢失。确定退出吗？'
                    : '退出后需要重新输入密码登录。'),
                actions: [
                  TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('取消')),
                  FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('退出')),
                ],
              ),
            );
            if (ok != true || !context.mounted) return;
            Navigator.of(context).pop();
            await s.logout();
          },
        ),
        const AboutListTile(
          icon: Icon(CupertinoIcons.info),
          applicationName: 'SyncNotes',
          applicationVersion: '0.2.0',
          applicationLegalese: '多设备实时同步笔记 / 消息队列',
        ),
      ]))),
    );
  }

  Widget _section(BuildContext context, String t) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
        child: Text(t,
            style: Theme.of(context)
                .textTheme
                .labelLarge
                ?.copyWith(color: Theme.of(context).colorScheme.primary)),
      );
}
