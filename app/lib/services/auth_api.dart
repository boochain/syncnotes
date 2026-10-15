import 'dart:convert';

import 'package:http/http.dart' as http;

class AuthResult {
  final String token;
  final String userId;
  final String username;
  AuthResult(this.token, this.userId, this.username);
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
    return u.replace(path: '');
  }

  Future<AuthResult> login(String server, String user, String pw, String deviceId,
      {String? deviceName}) async {
    final r = await _post(server, '/api/login', {
      'username': user,
      'password': pw,
      'device_id': deviceId,
      'device_name': deviceName,
    });
    return AuthResult(r['token'], r['user_id'], r['username']);
  }

  Future<void> register(String server, String user, String pw) async {
    await _post(server, '/api/register', {'username': user, 'password': pw});
  }

  Future<Map<String, dynamic>> _post(String server, String path, Map body) async {
    final http.Response res;
    try {
      res = await client
          .post(httpBase(server).replace(path: path),
              headers: {'content-type': 'application/json'}, body: jsonEncode(body))
          .timeout(const Duration(seconds: 10));
    } catch (e) {
      throw AuthException('无法连接服务器：$e');
    }
    if (res.statusCode >= 200 && res.statusCode < 300) {
      return jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    }
    final msg = utf8.decode(res.bodyBytes);
    throw AuthException(msg.isEmpty ? '请求失败 (${res.statusCode})' : msg);
  }

  /// 上传文件，返回 file_id。
  Future<String> uploadFile(String server, String token, String name, List<int> bytes) async {
    final res = await client.put(
      httpBase(server).replace(path: '/api/files', queryParameters: {'name': name}),
      headers: {'authorization': 'Bearer $token'},
      body: bytes,
    );
    if (res.statusCode != 200) throw AuthException('上传失败：${utf8.decode(res.bodyBytes)}');
    return (jsonDecode(res.body) as Map)['file_id'] as String;
  }

  Uri fileUrl(String server, String token, String fileId) =>
      httpBase(server).replace(path: '/api/files/$fileId', queryParameters: {'token': token});

  Future<List<int>> downloadFile(String server, String token, String fileId) async {
    final res = await client.get(fileUrl(server, token, fileId));
    if (res.statusCode != 200) throw AuthException('下载失败 (${res.statusCode})');
    return res.bodyBytes;
  }
}
