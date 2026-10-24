import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'package:cryptography/cryptography.dart';

import '../sync/wire_seal.dart';
import 'settings.dart';

class UploadedFile {
  final String id;
  final String sha256;
  final int size;
  const UploadedFile({required this.id, required this.sha256, required this.size});
}

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

/// HTTP 登录 / 注册 / 文件。默认走 syncnotes-seal-v1，明文 JSON 只在测试里关闭。
class AuthApi {
  final http.Client client;
  final bool wireSeal;
  final Settings? pins;
  AuthApi({http.Client? client, this.wireSeal = true, this.pins}) : client = client ?? http.Client();

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
      await _post(server, '/api/logout', {}, token: token);
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
    if (!wireSeal) return _postPlain(server, path, body, token: token);
    final http.Response res;
    final HttpPending pending;
    try {
      final pub = await WireSeal.serverPublic(server, pins: pins, client: client);
      final headers = utf8.encode(jsonEncode({
        if (token != null) 'authorization': 'Bearer $token',
      }));
      pending = await HttpPending.seal(
        serverPub: pub,
        method: 1,
        path: path,
        headersJson: headers,
        body: utf8.encode(jsonEncode(body)),
      );
      res = await client
          .post(endpoint(server, '/api/seal'),
              headers: {'content-type': 'application/octet-stream'}, body: pending.envelope)
          .timeout(const Duration(seconds: 15));
    } catch (e) {
      if (e is SealPinMismatch) rethrow;
      if (e is AuthException || e is WireException) throw AuthException('$e');
      throw AuthException('无法连接服务器：$e');
    }
    if (res.statusCode != 200) {
      throw AuthException(res.body.isEmpty ? '加密通道失败 (${res.statusCode})' : res.body);
    }
    final (status, raw) = await pending.openResponse(res.bodyBytes);
    return _decode(status, raw, path);
  }

  Future<Map<String, dynamic>> _postPlain(String server, String path, Map body, {String? token}) async {
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
    return _decode(res.statusCode, res.bodyBytes, path);
  }

  Map<String, dynamic> _decode(int status, List<int> raw, String path) {
    if (status == 204 || (status >= 200 && status < 300 && raw.isEmpty)) return <String, dynamic>{};
    if (status == 429) throw AuthException('尝试次数过多，请 15 分钟后再试');
    if (status == 404 && path != '/api/login') throw AuthException('服务器版本过旧，不支持此功能，请升级服务器');
    if (status >= 200 && status < 300) {
      if (raw.isEmpty) return <String, dynamic>{};
      return jsonDecode(utf8.decode(raw)) as Map<String, dynamic>;
    }
    final msg = utf8.decode(raw);
    throw AuthException(msg.isEmpty ? '请求失败 ($status)' : msg);
  }

  /// 流式上传。大文件按 256KB 分块加密，不把整文件再复制一份。
  /// 知道长度时带上 Content-Length，避免分块传输被中间代理掐断后停在 100%。
  Future<UploadedFile> putFile({
    required String server,
    required String token,
    required String name,
    List<int>? bytes,
    Stream<List<int>>? source,
    int total = 0,
    void Function(int done, int total)? onProgress,
    bool Function()? isCanceled,
  }) async {
    if (!wireSeal) {
      final data = bytes ?? await _collect(source);
      final id = await _putPlain(server, token, name, data);
      return UploadedFile(id: id, sha256: _sha256(data), size: data.length);
    }
    // 有流时 total 是已经数过的真实长度，0 表示空文件，不是“长度未知”。
    final known = bytes != null ? bytes.length : (source != null || total > 0 ? total : null);
    final pub = await WireSeal.serverPublic(server, pins: pins, client: client);
    final meta = utf8.encode(jsonEncode({
      'op': 'put',
      'name': name,
      'size': known ?? 0,
      'token': token,
    }));
    final pending = await HttpPending.seal(serverPub: pub, method: 3, path: '/api/blob', headersJson: utf8.encode('{}'), body: meta);
    final req = http.StreamedRequest('POST', endpoint(server, '/api/blob'));
    req.headers['content-type'] = 'application/octet-stream';
    if (known != null) req.contentLength = 4 + pending.envelope.length + _framedBytes(known);
    final sent = client.send(req);
    final hash = Sha256().toSync().newHashSink();
    try {
      req.sink.add(_u32(pending.envelope.length));
      req.sink.add(pending.envelope);
      final key = await pending.chunkKey();
      var idx = 0;
      var done = 0;
      final buf = _Buf();
      Future<void> emit(Uint8List plain) async {
        if (isCanceled?.call() == true) throw WireException('已取消');
        if (known != null && done + plain.length > known) {
          throw AuthException('文件长度和声明不一致（${done + plain.length} / $known）');
        }
        hash.add(plain);
        final ct = await sealChunk(key, idx++, plain);
        req.sink.add(_u32(ct.length));
        req.sink.add(ct);
        done += plain.length;
        final shown = known != null && known > 0 && done >= known ? known - 1 : done;
        onProgress?.call(shown < 0 ? 0 : shown, known == null || known == 0 ? done : known);
      }

      if (bytes != null) {
        final src = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
        for (var i = 0; i < src.length; i += WireSeal.chunkSize) {
          final n = i + WireSeal.chunkSize < src.length ? WireSeal.chunkSize : src.length - i;
          await emit(Uint8List.sublistView(src, i, i + n));
        }
      } else if (source != null) {
        await for (final part in source) {
          if (isCanceled?.call() == true) throw WireException('已取消');
          buf.add(part);
          while (buf.len >= WireSeal.chunkSize) {
            await emit(buf.take(WireSeal.chunkSize)!);
          }
        }
        final tail = buf.take(buf.len, partial: true);
        if (tail != null) await emit(tail);
      }
      if (known != null && done != known) {
        throw AuthException('文件长度和声明不一致（$done / $known）');
      }
      req.sink.add(_u32(0));
      await req.sink.close();
      // 字节已经交出去。界面显示“正在确认”，超时就失败，而不是停在 100%。
      if (known != null && known > 0) onProgress?.call(known, known);
      final res = await sent.timeout(const Duration(seconds: 90));
      final raw = await res.stream.toBytes().timeout(const Duration(seconds: 30));
      if (res.statusCode != 200) throw AuthException(_netText(utf8.decode(raw, allowMalformed: true)));
      final (status, body) = await pending.openResponse(raw);
      if (status != 200) throw AuthException(utf8.decode(body));
      final j = jsonDecode(utf8.decode(body)) as Map;
      hash.close();
      final sha = _hex(hash.hashSync().bytes);
      final remote = j['sha256'];
      if (remote is String && remote.isNotEmpty && remote != sha) throw AuthException('文件校验失败');
      final size = j['size'] is num ? (j['size'] as num).toInt() : done;
      onProgress?.call(size, size);
      return UploadedFile(id: j['file_id'] as String, sha256: sha, size: size);
    } catch (e) {
      try {
        await req.sink.close();
      } catch (_) {}
      // 长度不符时可能还没等响应。把发送的 Future 接住，避免连接错误变成未处理异常。
      unawaited(sent.then((r) => r.stream.drain<void>(), onError: (Object _) {}));
      if (e is AuthException) rethrow;
      if (e is WireException) throw AuthException('$e');
      throw AuthException(_netText('$e', upload: true));
    }
  }

  Future<String> _putPlain(String server, String token, String name, List<int> bytes) async {
    final res = await client.put(
      endpoint(server, '/api/files', {'name': name}),
      headers: {'authorization': 'Bearer $token'},
      body: bytes,
    );
    if (res.statusCode != 200) throw AuthException('上传失败：${utf8.decode(res.bodyBytes)}');
    return (jsonDecode(res.body) as Map)['file_id'] as String;
  }

  Future<List<int>> _collect(Stream<List<int>>? source) async {
    final b = BytesBuilder(copy: false);
    if (source != null) {
      await for (final c in source) {
        b.add(c);
      }
    }
    return b.takeBytes();
  }

  /// 上传文件，返回 file_id。
  Future<String> uploadFile(String server, String token, String name, List<int> bytes,
          {void Function(int done, int total)? onProgress, bool Function()? isCanceled}) async =>
      (await putFile(
          server: server,
          token: token,
          name: name,
          bytes: bytes,
          total: bytes.length,
          onProgress: onProgress,
          isCanceled: isCanceled))
          .id;

  Uri fileUrl(String server, String token, String fileId) =>
      endpoint(server, '/api/files/$fileId', {'token': token});

  Future<List<int>> downloadFile(String server, String token, String fileId,
      {void Function(int done, int total)? onProgress, bool Function()? isCanceled}) async {
    final b = BytesBuilder(copy: false);
    await downloadStream(server, token, fileId, (plain) async {
      b.add(plain);
    }, onProgress: onProgress, isCanceled: isCanceled);
    return b.takeBytes();
  }

  /// 流式下载到 [add]。进度按明文字节计。每个明文块交给 [add] 之后再读下一块，避免把整文件堆在内存里。
  Future<void> downloadStream(String server, String token, String fileId, Future<void> Function(List<int> plain) add,
      {void Function(int done, int total)? onProgress, bool Function()? isCanceled, String? expectSha256}) async {
    if (!wireSeal) {
      final res = await client.get(fileUrl(server, token, fileId));
      if (res.statusCode != 200) throw AuthException('下载失败 (${res.statusCode})');
      await add(res.bodyBytes);
      onProgress?.call(res.bodyBytes.length, res.bodyBytes.length);
      return;
    }
    final pub = await WireSeal.serverPublic(server, pins: pins, client: client);
    final meta = utf8.encode(jsonEncode({'op': 'get', 'file_id': fileId, 'token': token}));
    final pending =
        await HttpPending.seal(serverPub: pub, method: 3, path: '/api/blob', headersJson: utf8.encode('{}'), body: meta);
    final req = http.StreamedRequest('POST', endpoint(server, '/api/blob'));
    req.headers['content-type'] = 'application/octet-stream';
    req.contentLength = 4 + pending.envelope.length + 4;
    final sent = client.send(req);
    req.sink.add(_u32(pending.envelope.length));
    req.sink.add(pending.envelope);
    req.sink.add(_u32(0));
    await req.sink.close();
    final http.StreamedResponse res;
    try {
      res = await sent.timeout(const Duration(seconds: 90));
    } catch (e) {
      unawaited(sent.then((r) => r.stream.drain<void>(), onError: (Object _) {}));
      throw AuthException(_netText('$e'));
    }
    if (res.statusCode != 200) {
      final err = await res.stream.toBytes();
      throw AuthException(utf8.decode(err, allowMalformed: true));
    }
    final reader = _Reader(res.stream);
    try {
      final n = await reader.u32();
      if (n == 0x534E4331) {
        // 错误响应是一整段 SNC1 信封，不是长度前缀。前 4 字节已经读掉了。
        final rest = await reader.rest();
        final env = Uint8List(4 + rest.length);
        env[0] = 0x53;
        env[1] = 0x4e;
        env[2] = 0x43;
        env[3] = 0x31;
        env.setRange(4, env.length, rest);
        final (status, raw) = await pending.openResponse(env);
        final msg = utf8.decode(raw, allowMalformed: true);
        throw AuthException(msg.isEmpty ? '下载失败 ($status)' : msg);
      }
      if (n == 0 || n > 256 * 1024) throw AuthException('加密通道无效');
      final env = await reader.take(n);
      final (status, raw) = await pending.openResponse(env);
      if (status != 200) {
        final msg = utf8.decode(raw, allowMalformed: true);
        throw AuthException(msg.isEmpty ? '下载失败 ($status)' : msg);
      }
      var total = 0;
      try {
        final j = jsonDecode(utf8.decode(raw));
        if (j is Map && j['size'] is num) total = (j['size'] as num).toInt();
      } catch (_) {}
      final key = await pending.chunkKey();
      final hash = Sha256().toSync().newHashSink();
      var idx = 0;
      var done = 0;
      var serverSha = '';
      while (true) {
        if (isCanceled?.call() == true) throw WireException('已取消');
        final cn = await reader.u32();
        if (cn == 0) break;
        if (cn > 1024 * 1024 + 32) throw AuthException('分块过大');
        final ct = await reader.take(cn);
        final plain = await openChunk(key, idx++, ct);
        hash.add(plain);
        await add(plain);
        done += plain.length;
        final shown = total > 0 && done >= total ? total - 1 : done;
        onProgress?.call(shown < 0 ? 0 : shown, total == 0 ? done : total);
      }
      hash.close();
      final sha = _hex(hash.hashSync().bytes);
      try {
        final j = jsonDecode(utf8.decode(raw));
        if (j is Map && j['sha256'] is String) serverSha = j['sha256'] as String;
      } catch (_) {}
      if (serverSha.isNotEmpty && serverSha != sha) throw AuthException('文件校验失败');
      if (expectSha256 != null && expectSha256.isNotEmpty && expectSha256 != sha) throw AuthException('文件校验失败');
      onProgress?.call(done, total == 0 ? done : total);
    } catch (e) {
      if (e is AuthException) rethrow;
      if (e is WireException) throw AuthException('$e');
      throw AuthException('下载失败：$e');
    } finally {
      await reader.cancel();
    }
  }
}

Uint8List _u32(int n) => Uint8List.fromList([(n >> 24) & 255, (n >> 16) & 255, (n >> 8) & 255, n & 255]);

/// Ciphertext frames for [plain] bytes: each chunk is 4-byte length + plaintext + 16-byte tag, plus the terminator.
int _framedBytes(int plain) {
  const chunk = WireSeal.chunkSize;
  const tag = 16;
  if (plain <= 0) return 4;
  var n = 4;
  var left = plain;
  while (left > 0) {
    final take = left > chunk ? chunk : left;
    n += 4 + take + tag;
    left -= take;
  }
  return n;
}

String _hex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

String _sha256(List<int> b) {
  final s = Sha256().toSync().newHashSink();
  s.add(b);
  s.close();
  return _hex(s.hashSync().bytes);
}

String _netText(String raw, {bool upload = false}) {
  final s = raw.toLowerCase();
  if (s.contains('connection closed') ||
      s.contains('connection reset') ||
      s.contains('connection abort') ||
      s.contains('broken pipe') ||
      raw.contains('连接中断')) {
    return upload ? '上传失败：服务器关闭了连接。请确认服务器已升级到同一版本后重试。' : '下载失败：服务器关闭了连接。请确认服务器已升级到同一版本后重试。';
  }
  if (s.contains('timeout') || raw.contains('Timeout')) {
    return upload ? '上传失败：服务器没有确认，连接已中断。' : '下载失败：服务器没有确认，连接已中断。';
  }
  if (raw.startsWith('上传失败') || raw.startsWith('下载失败')) return raw;
  return upload ? '上传失败：$raw' : raw;
}

class _Reader {
  _Reader(this.stream) {
    _sub = stream.listen((d) {
      if (d.isEmpty) return;
      _chunks.add(d is Uint8List ? d : Uint8List.fromList(d));
      _avail += d.length;
      if (_avail > 512 * 1024) _sub?.pause();
      _wake();
    }, onError: (Object e) {
      _err = e;
      _done = true;
      _wake();
    }, onDone: () {
      _done = true;
      _wake();
    });
  }
  final Stream<List<int>> stream;
  final List<Uint8List> _chunks = [];
  int _off = 0;
  int _avail = 0;
  bool _done = false;
  Object? _err;
  StreamSubscription<List<int>>? _sub;
  final List<void Function()> _wait = [];

  void _wake() {
    final wait = List<void Function()>.of(_wait);
    _wait.clear();
    for (final w in wait) {
      w();
    }
  }

  void _resume() {
    if (_avail < 256 * 1024) _sub?.resume();
  }

  Future<void> _need(int n) async {
    while (_avail < n) {
      if (_err != null) throw _err!;
      if (_done) throw AuthException('连接中断');
      final c = Completer<void>();
      _wait.add(c.complete);
      await c.future.timeout(const Duration(minutes: 2), onTimeout: () {
        throw AuthException('连接中断');
      });
    }
  }

  Future<int> u32() async {
    final b = await take(4);
    return (b[0] << 24) | (b[1] << 16) | (b[2] << 8) | b[3];
  }

  Future<Uint8List> take(int n) async {
    if (n == 0) return Uint8List(0);
    await _need(n);
    final out = Uint8List(n);
    var filled = 0;
    while (filled < n) {
      final c = _chunks.first;
      final avail = c.length - _off;
      final k = avail < n - filled ? avail : n - filled;
      out.setRange(filled, filled + k, c, _off);
      filled += k;
      _off += k;
      _avail -= k;
      if (_off >= c.length) {
        _chunks.removeAt(0);
        _off = 0;
      }
    }
    _resume();
    return out;
  }

  Future<Uint8List> rest() async {
    _sub?.resume();
    while (!_done && _err == null) {
      final c = Completer<void>();
      _wait.add(c.complete);
      await c.future;
    }
    if (_err != null) throw _err!;
    return take(_avail);
  }

  Future<void> cancel() => _sub?.cancel() ?? Future.value();
}

class _Buf {
  final List<Uint8List> _parts = [];
  int _off = 0;
  int len = 0;

  void add(List<int> d) {
    if (d.isEmpty) return;
    final u = d is Uint8List ? d : Uint8List.fromList(d);
    _parts.add(u);
    len += u.length;
  }

  Uint8List? take(int n, {bool partial = false}) {
    if (n <= 0 || len == 0) return null;
    if (!partial && len < n) return null;
    final want = len < n ? len : n;
    final out = Uint8List(want);
    var filled = 0;
    while (filled < want) {
      final p = _parts.first;
      final avail = p.length - _off;
      final k = avail < want - filled ? avail : want - filled;
      out.setRange(filled, filled + k, p, _off);
      filled += k;
      _off += k;
      len -= k;
      if (_off >= p.length) {
        _parts.removeAt(0);
        _off = 0;
      }
    }
    return out;
  }
}

