import 'dart:async';
import 'dart:io';

/// 桌面单实例：第一个实例监听本机回环端口；再次启动时通知已有实例显示窗口后退出，
/// 避免出现两个托盘图标、两个同步连接。
class SingleInstance {
  static const int defaultPort = 47731;
  static ServerSocket? _server;

  /// 返回 true 表示当前是主实例；false 表示已有实例在运行（已通知其显示）。
  static Future<bool> acquire({int port = defaultPort, required void Function() onActivate}) async {
    try {
      _server = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
      _server!.listen((sock) {
        sock.listen((data) {
          if (String.fromCharCodes(data).contains('show')) onActivate();
        }, onError: (_) {}, cancelOnError: true);
        sock.close();
      });
      return true;
    } on SocketException {
      try {
        final s = await Socket.connect(InternetAddress.loopbackIPv4, port,
            timeout: const Duration(seconds: 1));
        s.write('show');
        await s.flush();
        await s.close();
        return false;
      } catch (_) {
        // 端口被其他程序占用：照常启动
        return true;
      }
    }
  }

  static Future<void> release() async {
    await _server?.close();
    _server = null;
  }
}
