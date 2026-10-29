import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'trash_page.dart';

import '../app_scope.dart';
import '../platform/android_service.dart';
import '../platform/desktop.dart';
import '../services/local_export.dart';
import '../sync/sync_client.dart';
import '../sync/wire_seal.dart';
import 'ds.dart';
import 'glass.dart';
import 'recovery_ui.dart';

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
          child: ListView(
            key: const Key('settingsList'),
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: const EdgeInsets.only(bottom: Gap.x3),
            children: [
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
                subtitle: [
                  '同步序号 ${s.sync.lastSeq} · 待发送 ${s.sync.pendingCount} · 设备 ${st.deviceId.length > 8 ? st.deviceId.substring(0, 8) : st.deviceId}',
                  if (s.sync.lastError != null) s.sync.lastError!,
                ].join('\n'),
                trailing: TextButton(onPressed: s.sync.reconnectNow, child: const Text('重连')),
              ),
            ),
            SettingsRow(
              key: const Key('settingsSeal'),
              icon: CupertinoIcons.checkmark_shield,
              title: '传输加密',
              subtitle: () {
                final pin = st.server == null ? null : st.sealPin(st.server!);
                if (pin == null || pin.isEmpty) {
                  return '第一次连上就记住服务器公钥。对不上就拒绝登录和同步。';
                }
                final short = pin.length > 16 ? '${pin.substring(0, 16)}…' : pin;
                return '已记住 $short。对不上就会停。重装或换数据目录都会变。';
              }(),
              trailing: TextButton(
                onPressed: () {
                  final server = st.server;
                  if (server != null) {
                    st.clearSealPin(server);
                    WireSeal.forget(server);
                  }
                  s.sync.reconnectNow();
                  setState(() {});
                },
                child: const Text('清除指纹'),
              ),
            ),
            if (st.localDataDir != null)
              SettingsRow(
                key: const Key('localDataDirRow'),
                icon: CupertinoIcons.folder,
                title: '本机数据目录',
                subtitle: '${st.localDataDir}\n登录、缓存和还没同步出去的修改都在这里，不在程序目录里。换版本、覆盖安装都不会清掉。',
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
            SettingsRow(
              key: const Key('settingsGlass'),
              icon: CupertinoIcons.drop,
              title: '液态玻璃',
              subtitle: st.liquidGlass ? '菜单和浮层会透出背景。页面保持不透明，切换时不会叠两层。' : '纯色界面',
              trailing: sw(st.liquidGlass, (v) {
                st.liquidGlass = v;
                Glass.enabled.value = v;
                setState(() {});
              }),
            ),
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
                        if (isDesktop) {
                          final ok = await DesktopShell.setAutoStart(v);
                          if (!ok) {
                            if (context.mounted) showToast(context, '开机自启没有写成功');
                            setState(() => _autoStart = !v);
                            return;
                          }
                        } else if (Platform.isAndroid) {
                          AndroidSyncService.init(autoRunOnBoot: v);
                          if (v && !st.foregroundService) st.foregroundService = true;
                          if (v) {
                            final ok = await AndroidSyncService.start();
                            if (!ok) {
                              st.autoStart = false;
                              if (context.mounted) showToast(context, '后台服务没有启动');
                              setState(() => _autoStart = false);
                              return;
                            }
                          }
                        }
                        st.autoStart = v;
                        setState(() => _autoStart = v);
                      },
                key: const Key('autoStartSwitch'),
              ),
            ),
            if (isDesktop)
              SettingsRow(
                icon: CupertinoIcons.eye_slash,
                title: '启动时最小化到托盘',
                subtitle: DesktopShell.instance.trayAvailable
                    ? '登录后启动只留托盘图标。开机自启也遵守这个开关。'
                    : '当前没有托盘图标，启动时仍会打开窗口，避免程序消失。',
                trailing: sw(st.startMinimized, (v) => setState(() => st.startMinimized = v)),
              ),
            if (isDesktop)
              SettingsRow(
                key: const Key('closeToTrayRow'),
                icon: CupertinoIcons.xmark_square,
                title: '关闭窗口时最小化到托盘',
                subtitle: !DesktopShell.instance.trayAvailable
                    ? (Platform.isLinux
                        ? '没有托盘图标，点关闭会退出。Linux 需安装 libayatana-appindicator3-1 后重启。'
                        : '没有托盘图标，点关闭会退出。')
                    : (st.closeToTray
                        ? '点关闭只是把窗口藏进托盘，程序还在。要退出：右键托盘图标选「退出」，或本页的「退出程序」。'
                        : '点关闭按钮直接退出 SyncNotes'),
                trailing: sw(st.closeToTray, (v) async {
                  if (v) {
                    final ok = await DesktopShell.instance.ensureTray();
                    if (!ok) {
                      if (context.mounted) showToast(context, '托盘没有起来，点关闭仍会退出');
                      setState(() => st.closeToTray = false);
                      await DesktopShell.instance.applyClosePolicy();
                      return;
                    }
                    if (context.mounted) {
                      showToast(context, '关闭按钮不会退出。右键托盘图标，选「退出」');
                    }
                  }
                  setState(() => st.closeToTray = v);
                  await DesktopShell.instance.applyClosePolicy();
                }, key: const Key('closeToTraySwitch')),
              ),
            if (Platform.isAndroid)
              SettingsRow(
                icon: CupertinoIcons.bell_circle,
                title: '后台保持连接（前台服务）',
                subtitle: '状态栏保留同步图标。关掉后切到别的应用就不再保持连接。',
                trailing: sw(st.foregroundService, (v) async {
                  if (v) {
                    AndroidSyncService.init(autoRunOnBoot: st.autoStart);
                    final ok = await AndroidSyncService.start();
                    if (!ok) {
                      if (context.mounted) showToast(context, '后台服务没有启动');
                      setState(() => st.foregroundService = false);
                      return;
                    }
                  } else {
                    await AndroidSyncService.stop();
                  }
                  setState(() => st.foregroundService = v);
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
            if (st.liquidGlass)
              Padding(
                padding: const EdgeInsets.fromLTRB(Gap.xl, Gap.s, Gap.xl, 0),
                child: Row(children: [
                  Text('玻璃透明度', style: Theme.of(context).textTheme.bodySmall),
                  Expanded(
                    child: Slider(
                      value: st.glassOpacity,
                      min: 0.35,
                      max: 0.92,
                      onChanged: (v) {
                        st.glassOpacity = v;
                        Glass.opacity.value = v;
                        setState(() {});
                      },
                    ),
                  ),
                ]),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(Gap.xl, Gap.s, Gap.xl, Gap.s),
              child: Wrap(spacing: Gap.s, runSpacing: Gap.s, children: [
                for (final (id, label) in const [('default', '默认'), ('sea', '海蓝'), ('dusk', '暮色'), ('paper', '纸色'), ('ink', '墨色')])
                  ChoiceChip(
                    label: Text(label),
                    selected: st.bgPreset == id,
                    onSelected: (_) {
                      st.bgPreset = id;
                      Glass.preset.value = id;
                      setState(() {});
                    },
                  ),
              ]),
            ),
            const _WireMap(),
            if (st.knownServers.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(Gap.xl, 0, Gap.xl, Gap.s),
                child: Wrap(spacing: Gap.s, runSpacing: Gap.s, children: [
                  for (final host in st.knownServers)
                    InputChip(
                      label: Text(host, overflow: TextOverflow.ellipsis),
                      onDeleted: host == st.server ? null : () => setState(() => st.forgetServer(host)),
                    ),
                ]),
              ),
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
              key: const Key('reuploadLocalRow'),
              icon: CupertinoIcons.arrow_up_circle,
              title: '重传本地缓存',
              subtitle: '把本机已有的笔记再发给服务器。服务器上更新的内容不会被盖掉。',
              onTap: () {
                final n = s.sync.reuploadLocal();
                showToast(context, n == 0 ? '没有可重传的内容' : '正在把 $n 条本地缓存发给服务器');
              },
            ),
            if (isDesktop)
              SettingsRow(
                key: const Key('quitAppRow'),
                icon: CupertinoIcons.clear_circled,
                title: '退出程序',
                subtitle: '结束 SyncNotes。打开「关闭窗口时最小化到托盘」后，点窗口的关闭按钮不会退出。',
                danger: true,
                onTap: () => DesktopShell.instance.quit(),
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

const appVersion = '0.6.12';

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

class _WireMap extends StatelessWidget {
  const _WireMap();

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final tt = Theme.of(context).textTheme;
    Widget row(String where, String how, bool sealed) => Padding(
          padding: const EdgeInsets.only(bottom: Gap.xs),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(sealed ? CupertinoIcons.lock_fill : CupertinoIcons.lock_open, size: Sizes.iconSm, color: sealed ? c.success : c.warning),
            const SizedBox(width: Gap.s),
            Expanded(child: Text('$where：$how', style: tt.bodySmall?.copyWith(color: c.text2))),
          ]),
        );
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.xl, Gap.s, Gap.xl, Gap.m),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('哪些地方是密文', style: tt.bodySmall?.copyWith(color: c.text)),
        const SizedBox(height: Gap.s),
        row('你的设备内存', '明文，否则你看不到笔记', false),
        row('线路上的笔记、密码、文件、同步', 'syncnotes-seal 密文，HTTP 也一样', true),
        row('地址是 https 时', '外面再包一层 TLS', true),
        row('/health', '明文，只有公钥，没有笔记', false),
        row('服务器硬盘', '明文。管服务器的人看得到', false),
        row('指纹', '认出是不是同一台服务器，不加密硬盘', false),
      ]),
    );
  }
}
