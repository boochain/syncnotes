import 'dart:io';

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

  static void init({required bool autoRunOnBoot}) {
    if (!supported) return;
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'syncnotes_service',
        channelName: '后台同步',
        channelDescription: '保持与服务器的实时连接',
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(60000),
        autoRunOnBoot: autoRunOnBoot,
        autoRunOnMyPackageReplaced: true,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
  }

  static Future<void> start() async {
    if (!supported) return;
    await FlutterForegroundTask.requestNotificationPermission();
    if (await FlutterForegroundTask.isRunningService) {
      await FlutterForegroundTask.restartService();
      return;
    }
    await FlutterForegroundTask.startService(
      serviceId: 7700,
      serviceTypes: [ForegroundServiceTypes.remoteMessaging],
      notificationTitle: 'SyncNotes 同步中',
      notificationText: '保持实时连接以接收新消息',
      callback: startSyncServiceCallback,
    );
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
    c.connect(server, token);
    _client = c;
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    final c = _client;
    if (c == null) return;
    c.reconnectNow();
    FlutterForegroundTask.updateService(
      notificationText: c.state == ConnState.online ? '已连接 · 实时同步中' : '正在重连…',
    );
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    _client?.dispose();
    _client = null;
  }
}
