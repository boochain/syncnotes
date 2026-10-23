import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:http/http.dart' as http;

import '../services/settings.dart';

/// syncnotes-seal-v1.
///
/// Plaintext exists only in this process and, after decrypt, in the server
/// process. HTTP bodies and WebSocket frames are ciphertext even on plain HTTP.
class WireException implements Exception {
  final String message;
  final bool fatal;
  WireException(this.message, {this.fatal = false});
  @override
  String toString() => message;
}

class WireSeal {
  static const chunkSize = 256 * 1024;
  static final _x = X25519();
  static final _aead = Chacha20.poly1305Aead();
  static final _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
  static final _pubs = <String, Uint8List>{};
  static final _memPin = <String, String>{};

  static Uri _base(String server) {
    var s = server.trim();
    if (!s.contains('://')) s = 'http://$s';
    s = s.replaceFirst(RegExp(r'^ws'), 'http');
    final u = Uri.parse(s);
    var path = u.path.endsWith('/') ? u.path.substring(0, u.path.length - 1) : u.path;
    if (path.endsWith('/ws')) path = path.substring(0, path.length - 3);
    return u.replace(path: path);
  }

  static String _hex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

  /// Server static public key. First sight is pinned; a later mismatch is refused.
  static Future<Uint8List> serverPublic(String server, {Settings? pins, http.Client? client}) async {
    final cached = _pubs[server];
    if (cached != null) return cached;
    final c = client ?? http.Client();
    final close = client == null;
    try {
      final r = await c.get(_base(server).replace(path: '${_base(server).path}/health')).timeout(const Duration(seconds: 8));
      if (r.statusCode != 200) throw WireException('服务器无响应 (${r.statusCode})', fatal: true);
      final j = jsonDecode(r.body);
      final b64 = j is Map ? j['seal_pub'] as String? : null;
      if (b64 == null || b64.isEmpty) {
        throw WireException('服务器过旧，没有加密通道，请升级服务器', fatal: true);
      }
      final pub = Uint8List.fromList(base64.decode(b64));
      if (pub.length != 32) throw WireException('服务器公钥无效', fatal: true);
      final hex = _hex(pub);
      final saved = pins?.sealPin(server) ?? _memPin[server];
      if (saved == null) {
        await pins?.setSealPin(server, hex);
        _memPin[server] = hex;
      } else if (saved != hex) {
        throw WireException('服务器指纹和上次不一致，已拒绝连接。若你重置了服务器密钥，到设置里清除指纹后再连。', fatal: true);
      }
      _pubs[server] = pub;
      return pub;
    } finally {
      if (close) c.close();
    }
  }

  static void forget(String server) {
    _pubs.remove(server);
    _memPin.remove(server);
  }

  static Future<Uint8List> _kdf(List<int> ikm, String info) async {
    final k = await _hkdf.deriveKey(
      secretKey: SecretKey(ikm),
      nonce: utf8.encode('syncnotes-seal-v1'),
      info: utf8.encode(info),
    );
    return Uint8List.fromList(await k.extractBytes());
  }

  static Future<Uint8List> _shared(KeyPair eph, List<int> remote) async {
    final s = await _x.sharedSecretKey(
      keyPair: eph,
      remotePublicKey: SimplePublicKey(remote, type: KeyPairType.x25519),
    );
    return Uint8List.fromList(await s.extractBytes());
  }

  static Future<Uint8List> _seal(List<int> key, List<int> nonce, List<int> aad, List<int> plain) async {
    final box = await _aead.encrypt(plain, secretKey: SecretKey(key), nonce: nonce, aad: aad);
    return Uint8List.fromList([...box.cipherText, ...box.mac.bytes]);
  }

  static Future<Uint8List> _pubBytes(KeyPair kp) async {
    final p = await kp.extractPublicKey();
    if (p is! SimplePublicKey || p.bytes.length != 32) throw WireException('公钥无效');
    return Uint8List.fromList(p.bytes);
  }

  static Future<Uint8List> _open(List<int> key, List<int> nonce, List<int> aad, List<int> ct) async {
    if (ct.length < 16) throw WireException('密文太短');
    final box = SecretBox(ct.sublist(0, ct.length - 16), nonce: nonce, mac: Mac(ct.sublist(ct.length - 16)));
    return Uint8List.fromList(await _aead.decrypt(box, secretKey: SecretKey(key), aad: aad));
  }

  static Uint8List _nonce12() {
    final n = Uint8List(12);
    final r = Random.secure();
    for (var i = 0; i < 12; i++) {
      n[i] = r.nextInt(256);
    }
    return n;
  }
}

class HttpPending {
  final KeyPair eph;
  final Uint8List serverPub;
  final Uint8List envelope;
  Uint8List? _shared;
  HttpPending(this.eph, this.serverPub, this.envelope);

  static Future<HttpPending> seal({
    required Uint8List serverPub,
    required int method,
    required String path,
    required List<int> headersJson,
    required List<int> body,
  }) async {
    final eph = await WireSeal._x.newKeyPair();
    final ephPub = await _pubBytes(eph);
    final shared = await WireSeal._shared(eph, serverPub);
    final key = await WireSeal._kdf(shared, 'http-req');
    final pb = utf8.encode(path);
    final plain = BytesBuilder(copy: false);
    plain.add([method]);
    plain.add([(pb.length >> 8) & 0xff, pb.length & 0xff]);
    plain.add(pb);
    plain.add([(headersJson.length >> 8) & 0xff, headersJson.length & 0xff]);
    plain.add(headersJson);
    plain.add(body);
    final nonce = WireSeal._nonce12();
    final ct = await WireSeal._seal(key, nonce, utf8.encode('syncnotes-http-v1-req'), plain.toBytes());
    final env = BytesBuilder(copy: false);
    env.add(utf8.encode('SNC1'));
    env.add(ephPub);
    env.add(nonce);
    env.add(ct);
    return HttpPending(eph, serverPub, env.toBytes()).._shared = shared;
  }

  Future<Uint8List> _ss() async => _shared ??= await WireSeal._shared(eph, serverPub);

  Future<(int, Uint8List)> openResponse(List<int> envelope) async {
    final plain = await _openEnv(envelope, await _ss(), 'http-res', 'syncnotes-http-v1-res');
    if (plain.length < 2) throw WireException('响应损坏');
    final status = (plain[0] << 8) | plain[1];
    return (status, Uint8List.sublistView(plain, 2));
  }

  Future<Uint8List> chunkKey() async => WireSeal._kdf(await _ss(), 'blob');

  static Future<Uint8List> _openEnv(List<int> envelope, List<int> shared, String info, String aad) async {
    if (envelope.length < 48 + 16 ||
        envelope[0] != 0x53 ||
        envelope[1] != 0x4e ||
        envelope[2] != 0x43 ||
        envelope[3] != 0x31) {
      throw WireException('加密通道无效');
    }
    final nonce = envelope.sublist(36, 48);
    final key = await WireSeal._kdf(shared, info);
    return WireSeal._open(key, nonce, utf8.encode(aad), envelope.sublist(48));
  }
}

Uint8List chunkNonce(int idx) {
  final n = Uint8List(12);
  var x = idx;
  for (var i = 11; i >= 4; i--) {
    n[i] = x & 0xff;
    x >>= 8;
  }
  return n;
}

Future<Uint8List> sealChunk(List<int> key, int idx, List<int> plain) =>
    WireSeal._seal(key, chunkNonce(idx), utf8.encode('syncnotes-blob-v1'), plain);

Future<Uint8List> openChunk(List<int> key, int idx, List<int> ct) =>
    WireSeal._open(key, chunkNonce(idx), utf8.encode('syncnotes-blob-v1'), ct);

class WsSession {
  final Uint8List key;
  int _send = 0;
  int _recv = 0;
  WsSession(this.key);

  Future<Uint8List> seal(List<int> plain) async {
    _send += 1;
    final nonce = _dirNonce(1, _send);
    final aad = [...utf8.encode('syncnotes-ws-v1'), 1];
    final ct = await WireSeal._seal(key, nonce, aad, plain);
    final out = BytesBuilder(copy: false);
    out.add(utf8.encode('SND1'));
    out.add(_u64(_send));
    out.add(ct);
    return out.toBytes();
  }

  Future<Uint8List> open(List<int> frame) async {
    if (frame.length < 4 + 8 + 16 || frame[0] != 0x53 || frame[1] != 0x4e || frame[2] != 0x44 || frame[3] != 0x31) {
      throw WireException('无法解密');
    }
    final seq = _readU64(frame, 4);
    if (seq != _recv + 1) throw WireException('帧序号错误');
    _recv = seq;
    final aad = [...utf8.encode('syncnotes-ws-v1'), 2];
    return WireSeal._open(key, _dirNonce(2, seq), aad, frame.sublist(12));
  }

  static Uint8List _dirNonce(int dir, int seq) {
    final n = Uint8List(12);
    n[0] = dir;
    final b = _u64(seq);
    n.setRange(1, 9, b);
    return n;
  }

  static Uint8List _u64(int v) {
    final b = Uint8List(8);
    var x = v;
    for (var i = 7; i >= 0; i--) {
      b[i] = x & 0xff;
      x >>= 8;
    }
    return b;
  }

  static int _readU64(List<int> b, int o) {
    var v = 0;
    for (var i = 0; i < 8; i++) {
      v = (v << 8) | b[o + i];
    }
    return v;
  }
}

/// Client handshake. [frames] yields the server hello then later data frames are left unread
/// only if the caller uses the same iterator afterwards — this function reads exactly one frame.
Future<WsSession> wsFinish(Uint8List serverPub, KeyPair eph, List<int> serverFrame) async {
  if (serverFrame.length != 4 + 32 + 16 || serverFrame[0] != 0x53 || serverFrame[3] != 0x31) {
    throw WireException('加密握手失败', fatal: true);
  }
  final serverEph = serverFrame.sublist(4, 36);
  final tag = serverFrame.sublist(36);
  final ssE = await WireSeal._shared(eph, serverEph);
  final ssS = await WireSeal._shared(eph, serverPub);
  final key = await WireSeal._kdf([...ssE, ...ssS], 'ws');
  final clientEph = await WireSeal._pubBytes(eph);
  final aad = [...clientEph, ...serverEph];
  final expect = await WireSeal._seal(key, Uint8List(12), aad, const []);
  if (expect.length != tag.length) throw WireException('服务器身份校验失败', fatal: true);
  for (var i = 0; i < tag.length; i++) {
    if (expect[i] != tag[i]) throw WireException('服务器身份校验失败', fatal: true);
  }
  return WsSession(key);
}

Future<Uint8List> clientHello(KeyPair eph) async {
  final pub = await WireSeal._pubBytes(eph);
  return Uint8List.fromList([...utf8.encode('SNW1'), ...pub]);
}

Future<KeyPair> newEph() => WireSeal._x.newKeyPair();
