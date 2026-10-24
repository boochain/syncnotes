import 'dart:io';
import 'package:flutter/foundation.dart' show kIsWeb;

import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../blocks/block_type.dart';
import '../models/block.dart';
import '../services/settings.dart';

/// 本地通知（无需任何付费推送服务；由实时连接驱动）。
class Notifier {
  static final _plugin = FlutterLocalNotificationsPlugin();
  static bool _ready = false;
  static int _id = 1000;

  /// 用户点击通知时要打开的块 id（外壳监听后打开对应内容）。
  static final opened = ValueNotifier<String?>(null);

  static void _onResponse(NotificationResponse r) {
    final id = r.payload;
    if (id == null || id.isEmpty) return;
    opened.value = null; // 同一条通知点两次也要触发
    opened.value = id;
  }

  /// Linux 通知依赖 D-Bus 会话总线；没有时（如无桌面会话）直接跳过。
  static bool get _linuxBusAvailable {
    if (!Platform.isLinux) return true;
    final env = Platform.environment['DBUS_SESSION_BUS_ADDRESS'];
    if (env != null && env.isNotEmpty) return true;
    final uid = Platform.environment['XDG_RUNTIME_DIR'];
    return uid != null && File('$uid/bus').existsSync();
  }

  /// [requestPermission] 只应在有界面的主隔离区为 true（后台服务中请求权限会失败）。
  static Future<void> init({bool requestPermission = true}) async {
    if (_ready || kIsWeb || !_linuxBusAvailable) return;
    try {
      await _plugin.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher_monochrome'),
          linux: LinuxInitializationSettings(defaultActionName: '打开'),
          windows: WindowsInitializationSettings(
            appName: 'SyncNotes',
            appUserModelId: 'com.frec86.syncnotes',
            guid: '5b0f3a4e-7c2d-4b8e-9a51-2f6e1d9c8a70',
          ),
        ),
        onDidReceiveNotificationResponse: _onResponse,
      );
      // 冷启动：应用是被点击通知拉起的
      if (requestPermission) {
        try {
          final launch = await _plugin.getNotificationAppLaunchDetails();
          final r = launch?.notificationResponse;
          if ((launch?.didNotificationLaunchApp ?? false) && r != null) _onResponse(r);
        } catch (_) {}
      }
      // Android 13+ 的运行时权限不在这里直接弹：先由界面说明用途（见 askAndroidPermission）
      _ready = true;
    } catch (e) {
      debugPrint('notifications unavailable: $e');
    }
  }

  static AndroidFlutterLocalNotificationsPlugin? get _android =>
      _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();

  /// Android：通知当前是否允许（Android 12 及以下默认允许）。
  static Future<bool> androidEnabled() async {
    if (!Platform.isAndroid) return true;
    try {
      return await _android?.areNotificationsEnabled() ?? true;
    } catch (_) {
      return true;
    }
  }

  /// Android 13+：弹出系统权限请求（调用前先向用户说明用途）。
  static Future<bool> requestAndroidPermission() async {
    if (!Platform.isAndroid) return true;
    try {
      return await _android?.requestNotificationsPermission() ?? false;
    } catch (_) {
      return false;
    }
  }

  static String bodyFor(Block b) {
    switch (b.kind) {
      case BlockKind.message:
        return (b.payload['text'] ?? '') as String;
      case BlockKind.note:
        final md = (b.payload['markdown'] ?? '') as String;
        return md.length > 120 ? '${md.substring(0, 120)}…' : md;
      case BlockKind.file:
        return '文件：${b.payload['name'] ?? b.title}';
      default:
        return b.title;
    }
  }

  static Future<void> showBlock(Block b) async {
    if (!_ready) await init(requestPermission: false);
    if (!_ready) return;
    final label = BlockTypes.isInitialized ? BlockTypes.of(b.kind).label : '新内容';
    try {
      await _plugin.show(
        id: _id++,
        title: '新$label：${b.title}',
        body: bodyFor(b),
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails('syncnotes_new', '新内容',
              channelDescription: '其他设备同步过来的新消息/笔记/文件',
              icon: '@mipmap/ic_launcher_monochrome',
              importance: Importance.high,
              priority: Priority.high),
          linux: LinuxNotificationDetails(),
          windows: WindowsNotificationDetails(),
        ),
        payload: b.id,
      );
    } catch (e) {
      debugPrint('notify failed: $e');
    }
  }
}

/// 通知权限说明（Android 13+）：先解释用途，用户同意后再弹系统权限框；只主动询问一次。
Future<void> askNotificationPermission(BuildContext context, Settings settings,
    {Future<bool> Function() isEnabled = Notifier.androidEnabled,
    Future<bool> Function() request = Notifier.requestAndroidPermission}) async {
  if (!settings.notifications || settings.notificationRationaleShown) return;
  if (await isEnabled()) return;
  if (!context.mounted) return;
  settings.notificationRationaleShown = true;
  final ok = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      key: const Key('notifRationale'),
      title: const Text('开启通知？'),
      content: const Text('其他设备发来新消息、笔记或文件时，SyncNotes 会用通知提醒你。可以随时在“设置”中关闭。'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('以后再说')),
        FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('开启')),
      ],
    ),
  );
  if (ok == true) await request();
}
