import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'crypto.dart';

class SessionInfo {
  final String token;
  final String userId;
  final String username;
  const SessionInfo({required this.token, required this.userId, required this.username});
}

class RemoteNote {
  final String id;
  final int updatedAt;
  final String nonce;
  final String ciphertext;
  const RemoteNote({required this.id, required this.updatedAt, required this.nonce, required this.ciphertext});

  factory RemoteNote.fromJson(Map<String, dynamic> j) => RemoteNote(
        id: j['id'] as String,
        updatedAt: (j['updated_at'] as num).toInt(),
        nonce: j['nonce'] as String,
        ciphertext: j['ciphertext'] as String,
      );
}

class Uploaded {
  final String id;
  final String name;
  final int size;
  const Uploaded({required this.id, required this.name, required this.size});
}

/// 没写协议时：域名用 https，IP / localhost / .local 用 http。
String normalizeServer(String raw) {
  var s = raw.trim();
  if (s.isEmpty) return s;
  if (!s.contains('://')) {
    final host = s.split('/').first.split(':').first;
    final local = host == 'localhost' || host.endsWith('.local') || RegExp(r'^(\d{1,3}\.){3}\d{1,3}$').hasMatch(host);
    s = '${local ? 'http' : 'https'}://$s';
  }
  while (s.endsWith('/')) {
    s = s.substring(0, s.length - 1);
  }
  return s;
}

class SyncApi {
  SyncApi({http.Client? client}) : client = client ?? http.Client();
  final http.Client client;

  static Uri endpoint(String server, String path) {
    final b = Uri.parse(normalizeServer(server));
    final base = b.path.endsWith('/') ? b.path.substring(0, b.path.length - 1) : b.path;
    return b.replace(path: '$base$path');
  }

  static Uri socketUri(String server, String token) {
    final httpUri = endpoint(server, '/v1/sync');
    final scheme = httpUri.scheme == 'https' ? 'wss' : 'ws';
    return httpUri.replace(scheme: scheme, queryParameters: {'token': token});
  }

  Future<SessionInfo> _auth(String server, String path, String username, String password) async {
    final res = await client
        .post(endpoint(server, path), headers: {'content-type': 'application/json'}, body: jsonEncode({'username': username, 'password': password}))
        .timeout(const Duration(seconds: 20));
    final map = _json(res);
    return SessionInfo(token: map['token'] as String, userId: map['user_id'] as String, username: map['username'] as String);
  }

  Future<SessionInfo> register(String server, String username, String password) => _auth(server, '/v1/register', username, password);

  Future<SessionInfo> login(String server, String username, String password) => _auth(server, '/v1/login', username, password);

  Future<List<RemoteNote>> notes(String server, String token) async {
    final res = await client.get(endpoint(server, '/v1/notes'), headers: {'authorization': 'Bearer $token'}).timeout(const Duration(seconds: 20));
    final raw = _ok(res);
    final list = jsonDecode(utf8.decode(raw)) as List;
    return list.map((e) => RemoteNote.fromJson(Map<String, dynamic>.from(e as Map))).toList();
  }

  Future<void> putNote(String server, String token, RemoteNote note) async {
    final res = await client
        .put(
          endpoint(server, '/v1/notes/${note.id}'),
          headers: {'authorization': 'Bearer $token', 'content-type': 'application/json'},
          body: jsonEncode({'updated_at': note.updatedAt, 'nonce': note.nonce, 'ciphertext': note.ciphertext}),
        )
        .timeout(const Duration(seconds: 20));
    if (res.statusCode == 409) throw SyncException('服务器上有更新的版本');
    _ok(res);
  }

  Future<void> deleteNote(String server, String token, String id) async {
    final res = await client.delete(endpoint(server, '/v1/notes/$id'), headers: {'authorization': 'Bearer $token'}).timeout(const Duration(seconds: 20));
    if (res.statusCode != 204 && res.statusCode != 200) _ok(res);
  }

  /// 上传已经加密好的文件。进度是套接字收下的字节，不到服务器回复不报完成。
  Future<Uploaded> uploadFile(
    String server,
    String token,
    File file, {
    required String name,
    void Function(int done, int total)? onProgress,
    void Function()? onWaiting,
  }) async {
    final total = await file.length();
    final io = HttpClient()..connectionTimeout = const Duration(seconds: 20);
    try {
      final req = await io.postUrl(endpoint(server, '/v1/files'));
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      req.headers.set('x-file-name', base64Url.encode(utf8.encode(name)).replaceAll('=', ''));
      req.headers.contentType = ContentType('application', 'octet-stream');
      req.contentLength = total;
      final raf = await file.open();
      try {
        var sent = 0;
        final buf = Uint8List(64 * 1024);
        while (sent < total) {
          final n = await raf.readInto(buf);
          if (n <= 0) break;
          req.add(Uint8List.sublistView(buf, 0, n));
          await req.flush();
          sent += n;
          final shown = total > 0 && sent >= total ? total - 1 : sent;
          onProgress?.call(shown < 0 ? 0 : shown, total);
        }
        if (sent != total) throw SyncException('文件长度和声明不一致（$sent / $total）');
      } finally {
        await raf.close();
      }
      onWaiting?.call();
      final HttpClientResponse res;
      try {
        res = await req.close().timeout(const Duration(seconds: 60));
      } on TimeoutException {
        io.close(force: true);
        throw SyncException('数据已经发出，服务器没有回复');
      }
      final raw = await res.fold<BytesBuilder>(BytesBuilder(copy: false), (b, c) {
        b.add(c);
        return b;
      }).timeout(const Duration(seconds: 30)).then((b) => b.takeBytes());
      if (res.statusCode == 413) throw SyncException('文件过大（最大 4 GB）');
      if (res.statusCode != 200) throw SyncException(_msg(res.statusCode, raw));
      final j = jsonDecode(utf8.decode(raw)) as Map<String, dynamic>;
      onProgress?.call(total, total);
      return Uploaded(id: j['id'] as String, name: j['name'] as String, size: (j['size'] as num).toInt());
    } on SyncException {
      io.close(force: true);
      rethrow;
    } catch (e) {
      io.close(force: true);
      throw SyncException('上传失败：$e');
    } finally {
      io.close(force: false);
    }
  }

  Future<void> downloadTo(
    String server,
    String token,
    String id,
    File dest, {
    void Function(int done, int total)? onProgress,
  }) async {
    final io = HttpClient()..connectionTimeout = const Duration(seconds: 20);
    try {
      final req = await io.getUrl(endpoint(server, '/v1/files/$id'));
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      final res = await req.close().timeout(const Duration(seconds: 60));
      if (res.statusCode != 200) {
        final raw = await res.fold<BytesBuilder>(BytesBuilder(copy: false), (b, c) {
          b.add(c);
          return b;
        });
        throw SyncException(_msg(res.statusCode, raw.takeBytes()));
      }
      final total = res.contentLength;
      final sink = dest.openWrite();
      var done = 0;
      try {
        await for (final c in res) {
          sink.add(c);
          done += c.length;
          final shown = total > 0 && done >= total ? total - 1 : done;
          onProgress?.call(shown < 0 ? 0 : shown, total < 0 ? done : total);
        }
      } finally {
        await sink.close();
      }
      onProgress?.call(done, total < 0 ? done : total);
    } on SyncException {
      rethrow;
    } catch (e) {
      throw SyncException('下载失败：$e');
    } finally {
      io.close(force: false);
    }
  }

  Map<String, dynamic> _json(http.Response res) {
    final raw = _ok(res);
    return jsonDecode(utf8.decode(raw)) as Map<String, dynamic>;
  }

  Uint8List _ok(http.Response res) {
    if (res.statusCode >= 200 && res.statusCode < 300) return res.bodyBytes;
    throw SyncException(_msg(res.statusCode, res.bodyBytes));
  }

  String _msg(int status, List<int> raw) {
    try {
      final j = jsonDecode(utf8.decode(raw));
      if (j is Map && j['error'] is String && (j['error'] as String).isNotEmpty) return j['error'] as String;
    } catch (_) {}
    if (status == 413) return '文件过大（最大 4 GB）';
    return '请求失败 ($status)';
  }
}
