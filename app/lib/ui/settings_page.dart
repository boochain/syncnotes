import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'trash_page.dart';

import '../app_scope.dart';
import '../platform/android_service.dart';
import '../platform/desktop.dart';
import '../sync/sync_client.dart';
import 'ds.dart';
import 'recovery_ui.dart';
import '../services/local_export.dart';

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
    Widget sw(bool v, ValueChanged<bool>? f, {Key? key}) => AppSwitch(key: key, value: v, onChanged: f);
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      // 设置页（照 Notion 设置 / HIG 分组列表）：内容限宽 680，分组标题 + 44 / 56 高的行
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: ListView(padding: const EdgeInsets.only(bottom: Gap.x3), children: [
            const SettingsSection('账号'),
            SettingsRow(icon: CupertinoIcons.person, title: st.username ?? '', subtitle: st.server ?? ''),
            ListenableBuilder(
              listenable: s.sync,
              builder: (c, _) => SettingsRow(
                key: const Key('connRow'),
                icon: CupertinoIcons.arrow_2_circlepath,
                title: switch (s.sync.state) {
                  ConnState.online => '已连接',
                  ConnState.connecting => '连接中…',
                  ConnState.authError => '登录已失效，请重新登录',
                  ConnState.offline => '离线（将自动重连）',
                },
                subtitle:
                    '同步序号 ${s.sync.lastSeq} · 待发送 ${s.sync.pendingCount} · 设备 ${st.deviceId.length > 8 ? st.deviceId.substring(0, 8) : st.deviceId}',
                trailing: TextButton(onPressed: s.sync.reconnectNow, child: const Text('重连')),
              ),
            ),
            SettingsRow(
              key: const Key('settingsRecoveryCode'),
              icon: CupertinoIcons.lock_shield,
              title: '生成 / 重置恢复码',
              subtitle: '忘记密码时用于自助重置，生成后旧恢复码失效',
              onTap: () => generateRecoveryCodeFlow(context,
                  api: s.api, server: st.server!, token: st.token!, username: st.username ?? ''),
            ),
            SettingsRow(
              key: const Key('settingsChangePassword'),
              icon: CupertinoIcons.lock_rotation,
              title: '修改密码',
              onTap: () async {
                final ok = await showChangePasswordDialog(context, api: s.api, server: st.server!, token: st.token!);
                if (ok != null && context.mounted) showToast(context, '密码已修改，其他设备需要重新登录');
              },
            ),
            SettingsRow(
              key: const Key('settingsExportData'),
              icon: CupertinoIcons.arrow_down_doc,
              title: '导出我的数据',
              subtitle: '把本机缓存的全部笔记、回收站和附件导出为 zip（不需要服务器）',
              onTap: () => exportMyData(context, s),
            ),
            const SettingsSection('外观'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Gap.xl, vertical: Gap.s),
              child: ValueListenableBuilder<ThemeMode>(
                valueListenable: s.themeMode,
                builder: (c, mode, _) => SegmentedControl<ThemeMode>(
                  key: const Key('themeSelector'),
                  segments: const [
                    (ThemeMode.system, CupertinoIcons.circle_lefthalf_fill, '跟随系统'),
                    (ThemeMode.light, CupertinoIcons.sun_max, '浅色'),
                    (ThemeMode.dark, CupertinoIcons.moon, '深色'),
                  ],
                  selected: mode,
                  onChanged: (v) {
                    s.themeMode.value = v;
                    st.themeMode = v.name;
                  },
                ),
              ),
            ),
            const SettingsSection('启动'),
            SettingsRow(
              icon: CupertinoIcons.power,
              title: Platform.isAndroid ? '开机自动启动后台同步' : '登录系统时自动启动',
              trailing: sw(
                _autoStart ?? false,
                _autoStart == null
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
                key: const Key('autoStartSwitch'),
              ),
            ),
            if (isDesktop)
              SettingsRow(
                icon: CupertinoIcons.eye_slash,
                title: '启动时最小化到托盘',
                trailing: sw(st.startMinimized, (v) => setState(() => st.startMinimized = v)),
              ),
            if (Platform.isAndroid)
              SettingsRow(
                icon: CupertinoIcons.bell_circle,
                title: '后台保持连接（前台服务）',
                subtitle: '常驻通知栏，保证及时收到新消息推送',
                trailing: sw(st.foregroundService, (v) async {
                  setState(() => st.foregroundService = v);
                  v ? await AndroidSyncService.start() : await AndroidSyncService.stop();
                }),
              ),
            const SettingsSection('通知与已读'),
            SettingsRow(
              icon: CupertinoIcons.bell,
              title: '新内容通知',
              trailing: sw(st.notifications, (v) => setState(() => st.notifications = v), key: const Key('notifySwitch')),
            ),
            SettingsRow(
              icon: CupertinoIcons.globe,
              title: '新建块默认使用全局已读',
              subtitle: st.defaultGlobalViewed ? '在一台设备上查看后，所有设备都标为已读' : '每台设备独立记录已读状态（可在每个块上单独切换）',
              trailing: sw(st.defaultGlobalViewed, (v) => setState(() => st.defaultGlobalViewed = v), key: const Key('globalSwitch')),
            ),
            const SettingsSection('其他'),
            SettingsRow(
              key: const Key('settingsTrash'),
              icon: CupertinoIcons.trash,
              title: '回收站',
              subtitle: '已删除的内容，可恢复或彻底删除',
              onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const TrashPage())),
            ),
            SettingsRow(
              icon: CupertinoIcons.arrow_clockwise,
              title: '清除本地缓存并重新同步',
              onTap: () async {
                await s.sync.clearLocal(keepPending: true);
                s.sync.reconnectNow();
                if (context.mounted) showToast(context, '已清除本地缓存，正在重新同步');
              },
            ),
            SettingsRow(
              key: const Key('logoutRow'),
              icon: CupertinoIcons.square_arrow_right,
              title: '退出登录',
              danger: true,
              onTap: () async {
                final pending = s.sync.pendingCount;
                final ok = await confirmDanger(context,
                    title: '退出登录？',
                    message: pending > 0 ? '还有 $pending 条修改尚未同步到服务器，退出后将丢失。确定退出吗？' : '退出后需要重新输入密码登录。',
                    confirm: '退出');
                if (!ok || !context.mounted) return;
                Navigator.of(context).pop();
                await s.logout();
              },
            ),
            SettingsRow(
              icon: CupertinoIcons.info,
              title: '关于 SyncNotes',
              onTap: () => showAboutDialog(
                context: context,
                applicationName: 'SyncNotes',
                applicationVersion: appVersion,
                applicationLegalese: '多设备实时同步笔记 / 消息队列',
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

const appVersion = '0.4.0';

/// 设置分组标题：12/500 次级色，上 24 下 4（Notion 设置分组）
class SettingsSection extends StatelessWidget {
  final String title;
  const SettingsSection(this.title, {super.key});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(Gap.xl, Gap.x3, Gap.xl, Gap.xs),
        child: Text(title,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppColors.of(context).text2, fontWeight: FontWeight.w500)),
      );
}

/// 设置行：单行 44、双行 56（最小高度；字号放大时自动增高不溢出）。左 20 图标位、右侧控件垂直居中。
class SettingsRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool danger;
  const SettingsRow({super.key, required this.icon, required this.title, this.subtitle, this.trailing, this.onTap, this.danger = false});

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final tt = Theme.of(context).textTheme;
    final fg = danger ? c.danger : c.text;
    final hasSub = subtitle != null && subtitle!.isNotEmpty;
    return InkWell(
      onTap: onTap,
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: hasSub ? Sizes.listRow : Sizes.bar),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: Gap.xl, vertical: Gap.s),
          child: Row(children: [
            SizedBox.square(dimension: Sizes.iconMd, child: Icon(icon, size: Sizes.iconMd - 2, color: danger ? c.danger : c.text2)),
            const SizedBox(width: Gap.l),
            Expanded(
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: tt.bodyMedium?.copyWith(color: fg)),
                if (hasSub) ...[
                  const SizedBox(height: 2),
                  Text(subtitle!, maxLines: 2, overflow: TextOverflow.ellipsis, style: tt.bodySmall?.copyWith(color: c.text2)),
                ],
              ]),
            ),
            if (trailing != null) ...[const SizedBox(width: Gap.l), trailing!],
            if (trailing == null && onTap != null && !danger) Icon(CupertinoIcons.chevron_right, size: 14, color: c.text3),
          ]),
        ),
      ),
    );
  }
}
