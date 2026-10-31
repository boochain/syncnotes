import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

class SealedNote {
  final String nonce;
  final String ciphertext;
  const SealedNote({required this.nonce, required this.ciphertext});
}

class SyncException implements Exception {
  final String message;
  SyncException(this.message);
  @override
  String toString() => message;
}

/// 笔记和文件在离开这台设备之前加密。同一密码在每台设备上推出同一把钥匙。
class NoteCipher {
  NoteCipher(this.key);
  final SecretKey key;
  static final Cipher _box = Xchacha20.poly1305Aead();
  static const chunkSize = 256 * 1024;
  static const magic = [0x53, 0x4e, 0x46, 0x31]; // SNF1

  static Future<NoteCipher> fromPassword(String password, {int memoryKiB = 8192, int iterations = 2}) async {
    final kdf = Argon2id(memory: memoryKiB, iterations: iterations, parallelism: 1, hashLength: 32);
    final secret = await kdf.deriveKeyFromPassword(password: password, nonce: utf8.encode('syncnotes-v1'));
    return NoteCipher(secret);
  }

  static NoteCipher fromBytes(List<int> bytes) => NoteCipher(SecretKey(bytes));

  Future<List<int>> extract() => key.extractBytes();

  Future<SealedNote> sealText(String plain) async {
    final nonce = _box.newNonce();
    final box = await _box.encrypt(utf8.encode(plain), secretKey: key, nonce: nonce);
    return SealedNote(nonce: base64Encode(box.nonce), ciphertext: base64Encode(box.concatenation(nonce: false)));
  }

  Future<String> openText(String nonceB64, String ctB64) async {
    try {
      final nonce = base64Decode(nonceB64);
      final ct = base64Decode(ctB64);
      final data = Uint8List(nonce.length + ct.length)..setAll(0, nonce)..setAll(nonce.length, ct);
      final box = SecretBox.fromConcatenation(data, nonceLength: _box.nonceLength, macLength: 16);
      return utf8.decode(await _box.decrypt(box, secretKey: key));
    } on SecretBoxAuthenticationError {
      throw SyncException('无法解密，密码和写下这篇笔记时不一致');
    }
  }

  Future<Uint8List> sealBytes(List<int> plain, {int chunk = chunkSize}) async {
    final out = BytesBuilder(copy: false);
    out.add(magic);
    final src = plain is Uint8List ? plain : Uint8List.fromList(plain);
    if (src.isNotEmpty) {
      for (var i = 0; i < src.length;) {
        final n = i + chunk < src.length ? chunk : src.length - i;
        await _writeChunk(out.add, Uint8List.sublistView(src, i, i + n));
        i += n;
      }
    }
    return out.toBytes();
  }

  Future<Uint8List> openBytes(List<int> sealed) async {
    final out = BytesBuilder(copy: false);
    await openTo(Stream.value(sealed), out.add);
    return out.toBytes();
  }

  Future<void> sealTo(Stream<List<int>> src, void Function(List<int>) add, {int chunk = chunkSize, void Function(int plainBytes)? onPlain}) async {
    add(magic);
    final q = _Buf();
    var plain = 0;
    await for (final part in src) {
      q.add(part);
      plain += part.length;
      while (q.len >= chunk) {
        await _writeChunk(add, q.take(chunk)!);
      }
      onPlain?.call(plain);
    }
    if (q.len > 0) await _writeChunk(add, q.take(q.len)!);
  }

  Future<void> openTo(Stream<List<int>> src, void Function(List<int>) add) async {
    final q = _Buf();
    var magicOk = false;
    await for (final part in src) {
      q.add(part);
      magicOk = await _drain(q, add, magicOk, end: false);
    }
    await _drain(q, add, magicOk, end: true);
  }

  Future<void> _writeChunk(void Function(List<int>) add, Uint8List plain) async {
    final nonce = _box.newNonce();
    final box = await _box.encrypt(plain, secretKey: key, nonce: nonce);
    final ct = box.concatenation(nonce: false);
    add(_u32(nonce.length + ct.length));
    add(nonce);
    add(ct);
  }

  Future<bool> _drain(_Buf q, void Function(List<int>) add, bool magicOk, {required bool end}) async {
    if (!magicOk) {
      if (q.len < 4) {
        if (end) throw SyncException('文件损坏');
        return false;
      }
      final m = q.take(4)!;
      for (var i = 0; i < 4; i++) {
        if (m[i] != magic[i]) throw SyncException('文件不是本应用加密的');
      }
      magicOk = true;
    }
    while (q.len >= 4) {
      final n = q.peekU32();
      if (n == null) break;
      if (n < 24 + 16 || n > 1024 * 1024 + 64) throw SyncException('分块过大');
      if (q.len < 4 + n) break;
      q.take(4);
      final frame = q.take(n)!;
      final nonce = Uint8List.sublistView(frame, 0, _box.nonceLength);
      final ct = Uint8List.sublistView(frame, _box.nonceLength);
      final data = Uint8List(nonce.length + ct.length)..setAll(0, nonce)..setAll(nonce.length, ct);
      try {
        final box = SecretBox.fromConcatenation(data, nonceLength: _box.nonceLength, macLength: 16);
        add(await _box.decrypt(box, secretKey: key));
      } on SecretBoxAuthenticationError {
        throw SyncException('文件校验失败');
      }
    }
    if (end && q.len != 0) throw SyncException('文件损坏');
    return true;
  }
}

Uint8List _u32(int n) => Uint8List.fromList([(n >> 24) & 255, (n >> 16) & 255, (n >> 8) & 255, n & 255]);

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

  int? peekU32() {
    if (len < 4) return null;
    final b = Uint8List(4);
    var filled = 0;
    var off = _off;
    var i = 0;
    while (filled < 4) {
      final p = _parts[i];
      final avail = p.length - off;
      final k = avail < 4 - filled ? avail : 4 - filled;
      b.setRange(filled, filled + k, p, off);
      filled += k;
      i++;
      off = 0;
    }
    return (b[0] << 24) | (b[1] << 16) | (b[2] << 8) | b[3];
  }

  Uint8List? take(int n) {
    if (n <= 0 || len < n) return null;
    final out = Uint8List(n);
    var filled = 0;
    while (filled < n) {
      final p = _parts.first;
      final avail = p.length - _off;
      final k = avail < n - filled ? avail : n - filled;
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
