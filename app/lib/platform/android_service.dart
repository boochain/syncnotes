import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../platform/notifications.dart';
import '../services/settings.dart';
import '../sync/local_store.dart';
import '../sync/sync_client.dart';

/// Android 前台服务：在后台保持 WebSocket 长连接，收到新内容时发本地通知。
/// 开启"开机自启"时，服务会在开机后自动运行（autoRunOnBoot）。
class AndroidSyncService {
  static bool get supported => Platform.isAndroid;

  /// 状态栏小图标必须是单色。用启动器彩色图标时，不少系统会直接不显示这条通知。
  static const serviceIcon = NotificationIcon(metaDataName: 'com.syncnotes.service_icon');

  static void init({required bool autoRunOnBoot}) {
    if (!supported) return;
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'syncnotes_bg',
        channelName: '后台同步',
        channelDescription: '保持与服务器的实时连接',
        // LOW 会被系统当成静默通知，状态栏图标默认隐藏。DEFAULT 才固定出现在状态栏，声音仍然关掉。
        channelImportance: NotificationChannelImportance.DEFAULT,
        priority: NotificationPriority.DEFAULT,
        playSound: false,
        enableVibration: false,
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(60000),
        autoRunOnBoot: autoRunOnBoot,
        autoRunOnMyPackageReplaced: true,
        allowWakeLock: true,
        allowWifiLock: true,
        allowAutoRestart: true,
        stopWithTask: false,
      ),
    );
  }

  static Future<bool> start() async {
    if (!supported) return false;
    try {
      await FlutterForegroundTask.requestNotificationPermission();
      // 正在跑的服务还记着旧的通知渠道（静默、没有小图标）。停掉再用新设置拉起来。
      if (await FlutterForegroundTask.isRunningService) {
        await FlutterForegroundTask.stopService();
      }
      final result = await FlutterForegroundTask.startService(
        serviceId: 7700,
        serviceTypes: [ForegroundServiceTypes.remoteMessaging],
        notificationTitle: 'SyncNotes 同步中',
        notificationText: '正在连接…',
        notificationIcon: serviceIcon,
        callback: startSyncServiceCallback,
      );
      if (result is ServiceRequestFailure) {
        debugPrint('foreground service: ${result.error}');
        return false;
      }
      await _askBatteryOnce();
      return true;
    } catch (e) {
      debugPrint('foreground service: $e');
      return false;
    }
  }

  static Future<void> _askBatteryOnce() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool('asked_battery') ?? false) return;
      if (await FlutterForegroundTask.isIgnoringBatteryOptimizations) {
        await prefs.setBool('asked_battery', true);
        return;
      }
      await FlutterForegroundTask.requestIgnoreBatteryOptimization();
      await prefs.setBool('asked_battery', true);
    } catch (e) {
      debugPrint('battery optimization: $e');
    }
  }

  static Future<void> stop() async {
    if (!supported) return;
    await FlutterForegroundTask.stopService();
  }
}

@pragma('vm:entry-point')
void startSyncServiceCallback() {
  FlutterForegroundTask.setTaskHandler(_SyncTaskHandler());
}

class _SyncTaskHandler extends TaskHandler {
  SyncClient? _client;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    DartPluginRegistrant.ensureInitialized();
    final prefs = await SharedPreferences.getInstance();
    final server = prefs.getString('server');
    final token = prefs.getString('token');
    final deviceId = prefs.getString('device_id');
    if (server == null || token == null || deviceId == null) return;
    await Notifier.init(requestPermission: false);
    // 服务隔离区只负责通知：使用内存存储，首次追赶不提示。
    final settings = Settings(prefs);
    final c = SyncClient(store: MemoryStore(), deviceId: deviceId, settings: settings);
    c.onRemoteNew = (b) {
      if (prefs.getBool('notifications') ?? true) Notifier.showBlock(b);
    };
    c.addListener(() => _note(c));
    c.connect(server, token);
    _client = c;
    _note(c);
  }

  void _note(SyncClient c) {
    final text = switch (c.state) {
      ConnState.online => '已连接 · 实时同步中',
      ConnState.connecting => '正在连接…',
      _ => '网络中断，正在重试',
    };
    FlutterForegroundTask.updateService(notificationText: text);
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    final c = _client;
    if (c == null) return;
    // 在线就别拆连接。每分钟无条件重连会把正在进行的握手掐掉，通知就一直写着重连。
    if (c.state != ConnState.online) c.reconnectNow();
    _note(c);
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    _client?.dispose();
    _client = null;
  }
}
