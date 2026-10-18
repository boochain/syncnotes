import 'dart:convert';

import 'package:http/http.dart' as http;

class AuthResult {
  final String token;
  final String userId;
  final String username;
  /// 一次性恢复码（仅在刚生成时返回，只显示一次）。
  final String? recoveryCode;
  /// 旧账号没有恢复码时为 false（登录后提示生成一次）。
  final bool hasRecoveryCode;
  /// 管理员重置为临时密码后必须先修改密码。
  final bool mustChangePassword;
  AuthResult(this.token, this.userId, this.username,
      {this.recoveryCode, this.hasRecoveryCode = true, this.mustChangePassword = false});

  factory AuthResult.fromJson(Map<String, dynamic> r) => AuthResult(
        r['token'] as String,
        r['user_id'] as String,
        r['username'] as String,
        recoveryCode: r['recovery_code'] as String?,
        // 旧服务器不返回该字段：视为已有，避免误提示
        hasRecoveryCode: (r['has_recovery_code'] as bool?) ?? true,
        mustChangePassword: (r['must_change_password'] as bool?) ?? false,
      );
}

class AuthException implements Exception {
  final String message;
  AuthException(this.message);
  @override
  String toString() => message;
}

/// HTTP 登录 / 注册 / 文件上传。
class AuthApi {
  final http.Client client;
  AuthApi({http.Client? client}) : client = client ?? http.Client();

  static Uri httpBase(String server) {
    var s = server.trim();
    if (!s.contains('://')) s = 'http://$s';
    s = s.replaceFirst(RegExp(r'^ws'), 'http');
    final u = Uri.parse(s);
    var path = u.path.endsWith('/') ? u.path.substring(0, u.path.length - 1) : u.path;
    if (path.endsWith('/ws')) path = path.substring(0, path.length - 3);
    return u.replace(path: path);
  }

  /// 在基础地址（可能带路径前缀）后拼接 API 路径。
  static Uri endpoint(String server, String path, [Map<String, String>? query]) {
    final b = httpBase(server);
    return b.replace(path: '${b.path}$path', queryParameters: query);
  }

  /// 吊销服务器上的令牌（失败忽略：离线时也允许退出）。
  Future<void> logout(String server, String token) async {
    try {
      await client
          .post(endpoint(server, '/api/logout'), headers: {'authorization': 'Bearer $token'})
          .timeout(const Duration(seconds: 5));
    } catch (_) {}
  }

  /// 服务器健康信息（协议版本、回收站保留天数）。失败返回 null。
  Future<Map<String, dynamic>?> health(String server) async {
    try {
      final r = await client.get(endpoint(server, '/health')).timeout(const Duration(seconds: 5));
      if (r.statusCode != 200) return null;
      return Map<String, dynamic>.from(jsonDecode(r.body) as Map);
    } catch (_) {
      return null;
    }
  }

  Future<AuthResult> login(String server, String user, String pw, String deviceId,
      {String? deviceName}) async {
    final r = await _post(server, '/api/login', {
      'username': user,
      'password': pw,
      'device_id': deviceId,
      'device_name': deviceName,
    });
    return AuthResult.fromJson(r);
  }

  /// 注册；返回服务器生成的一次性恢复码（旧服务器返回 null）。
  Future<String?> register(String server, String user, String pw) async {
    final r = await _post(server, '/api/register', {'username': user, 'password': pw});
    return r['recovery_code'] as String?;
  }

  /// 忘记密码：用户名 + 恢复码 + 新密码。成功后所有旧会话失效，返回新令牌和新的恢复码。
  Future<AuthResult> recover(String server, String user, String code, String newPw, String deviceId,
      {String? deviceName}) async {
    final r = await _post(server, '/api/recover', {
      'username': user,
      'recovery_code': code,
      'new_password': newPw,
      'device_id': deviceId,
      'device_name': deviceName,
    });
    return AuthResult.fromJson(r);
  }

  /// 生成 / 重置恢复码（需要当前密码）。
  Future<String> regenerateRecoveryCode(String server, String token, String password) async {
    final r = await _post(server, '/api/recovery-code', {'password': password}, token: token);
    return r['recovery_code'] as String;
  }

  /// 修改密码（保留当前会话，其他设备需重新登录）。
  Future<void> changePassword(String server, String token, String oldPw, String newPw) async {
    await _post(server, '/api/change-password', {'old_password': oldPw, 'new_password': newPw}, token: token);
  }

  Future<Map<String, dynamic>> _post(String server, String path, Map body, {String? token}) async {
    final http.Response res;
    try {
      res = await client
          .post(endpoint(server, path),
              headers: {
                'content-type': 'application/json',
                if (token != null) 'authorization': 'Bearer $token',
              },
              body: jsonEncode(body))
          .timeout(const Duration(seconds: 10));
    } catch (e) {
      throw AuthException('无法连接服务器：$e');
    }
    if (res.statusCode == 204 || (res.statusCode >= 200 && res.statusCode < 300 && res.bodyBytes.isEmpty)) {
      return <String, dynamic>{};
    }
    if (res.statusCode == 429) throw AuthException('尝试次数过多，请 15 分钟后再试');
    if (res.statusCode == 404 && path != '/api/login') throw AuthException('服务器版本过旧，不支持此功能，请升级服务器');
    if (res.statusCode >= 200 && res.statusCode < 300) {
      return jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    }
    final msg = utf8.decode(res.bodyBytes);
    throw AuthException(msg.isEmpty ? '请求失败 (${res.statusCode})' : msg);
  }

  /// 上传文件，返回 file_id。
  Future<String> uploadFile(String server, String token, String name, List<int> bytes) async {
    final res = await client.put(
      endpoint(server, '/api/files', {'name': name}),
      headers: {'authorization': 'Bearer $token'},
      body: bytes,
    );
    if (res.statusCode != 200) throw AuthException('上传失败：${utf8.decode(res.bodyBytes)}');
    return (jsonDecode(res.body) as Map)['file_id'] as String;
  }

  Uri fileUrl(String server, String token, String fileId) =>
      endpoint(server, '/api/files/$fileId', {'token': token});

  Future<List<int>> downloadFile(String server, String token, String fileId) async {
    final res = await client.get(fileUrl(server, token, fileId));
    if (res.statusCode != 200) throw AuthException('下载失败 (${res.statusCode})');
    return res.bodyBytes;
  }
}
