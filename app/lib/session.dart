import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'settings_store.dart';
import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/io.dart';

import 'api.dart';
import 'crypto.dart';

class Attachment {
  final String id;
  final String name;
  final int size;
  const Attachment({required this.id, required this.name, required this.size});
}

class Note {
  Note({required this.id, this.title = '', this.body = '', List<Attachment>? files, required this.updatedAt, this.dirty = false})
      : files = files ?? [];

  final String id;
  String title;
  String body;
  final List<Attachment> files;
  int updatedAt;
  bool dirty;

  String get heading => title.trim().isEmpty ? '无标题' : title.trim();

  String encode() => jsonEncode({
        'title': title,
        'body': body,
        'files': [for (final f in files) {'id': f.id, 'name': f.name, 'size': f.size}],
      });

  static Note decode(String id, String plain, int updatedAt) {
    final j = jsonDecode(plain);
    if (j is! Map) return Note(id: id, body: plain, updatedAt: updatedAt);
    final files = <Attachment>[];
    final raw = j['files'];
    if (raw is List) {
      for (final e in raw) {
        if (e is Map && e['id'] is String) {
          files.add(Attachment(id: e['id'] as String, name: '${e['name'] ?? 'file'}', size: (e['size'] as num?)?.toInt() ?? 0));
        }
      }
    }
    return Note(id: id, title: '${j['title'] ?? ''}', body: '${j['body'] ?? ''}', files: files, updatedAt: updatedAt);
  }

  Map<String, dynamic> toCache() => {
        'id': id,
        'title': title,
        'body': body,
        'updatedAt': updatedAt,
        'dirty': dirty,
        'files': [for (final f in files) {'id': f.id, 'name': f.name, 'size': f.size}],
      };

  factory Note.fromCache(Map<String, dynamic> j) {
    final files = <Attachment>[];
    final raw = j['files'];
    if (raw is List) {
      for (final e in raw) {
        if (e is Map && e['id'] is String) {
          files.add(Attachment(id: e['id'] as String, name: '${e['name'] ?? 'file'}', size: (e['size'] as num?)?.toInt() ?? 0));
        }
      }
    }
    return Note(
      id: j['id'] as String,
      title: '${j['title'] ?? ''}',
      body: '${j['body'] ?? ''}',
      files: files,
      updatedAt: (j['updatedAt'] as num?)?.toInt() ?? 0,
      dirty: j['dirty'] == true,
    );
  }
}

class Transfer {
  Transfer({required this.name, this.done = 0, this.total = 0, this.waiting = false, this.error});
  final String name;
  int done;
  int total;
  bool waiting;
  String? error;
  double get fraction => total <= 0 ? 0 : (done / total).clamp(0, 1);
}

class Session extends ChangeNotifier {
  Session({required this.prefs, required this.api, required this.supportDir});

  final SettingsStore prefs;
  final SyncApi api;
  final Directory supportDir;
  final notes = <Note>[];
  final transfer = ValueNotifier<Transfer?>(null);
  NoteCipher? cipher;
  String? token;
  String? server;
  String? username;
  String? error;
  bool busy = false;
  IOWebSocketChannel? _socket;
  StreamSubscription<dynamic>? _sub;
  bool _closed = false;

  bool get signedIn => token != null && cipher != null && server != null;

  String get themeMode => prefs.getString('theme_mode') ?? 'system';
  set themeMode(String v) {
    prefs.setString('theme_mode', v);
    notifyListeners();
  }

  bool get windowExpanded => prefs.getBool('window_expanded') ?? true;
  set windowExpanded(bool v) {
    prefs.setBool('window_expanded', v);
    notifyListeners();
  }

  Future<void> restore() async {
    server = prefs.getString('server');
    token = prefs.getString('token');
    username = prefs.getString('username');
    final key = prefs.getString('key');
    if (key != null && key.isNotEmpty) {
      cipher = NoteCipher.fromBytes(base64Decode(key));
    }
    await _loadCache();
    if (signedIn) unawaited(sync());
    notifyListeners();
  }

  Future<void> login({required String server, required String username, required String password, required bool register}) async {
    error = null;
    busy = true;
    notifyListeners();
    try {
      final s = normalizeServer(server);
      final session = register ? await api.register(s, username.trim(), password) : await api.login(s, username.trim(), password);
      final box = await NoteCipher.fromPassword(password);
      cipher = box;
      token = session.token;
      this.server = s;
      this.username = session.username;
      await prefs.setString('server', s);
      await prefs.setString('token', session.token);
      await prefs.setString('username', session.username);
      await prefs.setString('key', base64Encode(await box.extract()));
      await sync();
    } on SyncException catch (e) {
      error = e.message;
    } catch (e) {
      error = '登录失败：$e';
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> logout() async {
    await _sub?.cancel();
    await _socket?.sink.close();
    _socket = null;
    token = null;
    cipher = null;
    username = null;
    notes.clear();
    await prefs.remove('token');
    await prefs.remove('key');
    await prefs.remove('username');
    await _cacheFile().writeAsString('[]');
    notifyListeners();
  }

  Note create() {
    final n = Note(id: const Uuid().v4(), updatedAt: DateTime.now().millisecondsSinceEpoch, dirty: true);
    notes.insert(0, n);
    notifyListeners();
    unawaited(_saveCache());
    unawaited(push(n));
    return n;
  }

  void edit(Note n, {String? title, String? body}) {
    if (title != null) n.title = title;
    if (body != null) n.body = body;
    n.updatedAt = DateTime.now().millisecondsSinceEpoch;
    n.dirty = true;
    notes.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    notifyListeners();
    unawaited(_saveCache());
  }

  Future<void> push(Note n) async {
    final box = cipher;
    final tok = token;
    final host = server;
    if (box == null || tok == null || host == null) return;
    try {
      final sealed = await box.sealText(n.encode());
      await api.putNote(host, tok, RemoteNote(id: n.id, updatedAt: n.updatedAt, nonce: sealed.nonce, ciphertext: sealed.ciphertext));
      n.dirty = false;
      await _saveCache();
      notifyListeners();
    } on SyncException catch (e) {
      error = e.message;
      notifyListeners();
    } catch (e) {
      error = '同步失败：$e';
      notifyListeners();
    }
  }

  Future<void> remove(Note n) async {
    notes.remove(n);
    notifyListeners();
    await _saveCache();
    final tok = token;
    final host = server;
    if (tok == null || host == null) return;
    try {
      await api.deleteNote(host, tok, n.id);
    } catch (e) {
      error = '删除失败：$e';
      notifyListeners();
    }
  }

  Future<void> attach(Note n, String name, Stream<List<int>> Function() open, int size) async {
    final box = cipher;
    final tok = token;
    final host = server;
    if (box == null || tok == null || host == null) return;
    final job = Transfer(name: name, total: size);
    transfer.value = job;
    final tmp = File('${supportDir.path}${Platform.pathSeparator}upload-$name.bin');
    try {
      final sink = tmp.openWrite();
      await box.sealTo(open(), sink.add, onPlain: (p) {
        job.done = p;
        job.total = size == 0 ? p : size;
        transfer.value = job;
      });
      await sink.flush();
      await sink.close();
      job.done = 0;
      job.total = await tmp.length();
      job.waiting = false;
      transfer.value = job;
      final up = await api.uploadFile(host, tok, tmp, name: name, onProgress: (d, t) {
        job.done = d;
        job.total = t;
        job.waiting = false;
        transfer.value = job;
      }, onWaiting: () {
        job.waiting = true;
        transfer.value = job;
      });
      n.files.add(Attachment(id: up.id, name: up.name, size: up.size));
      n.updatedAt = DateTime.now().millisecondsSinceEpoch;
      n.dirty = true;
      await push(n);
      transfer.value = null;
    } on SyncException catch (e) {
      job.error = e.message;
      transfer.value = job;
    } catch (e) {
      job.error = '上传失败：$e';
      transfer.value = job;
    } finally {
      if (await tmp.exists()) await tmp.delete();
    }
  }

  Future<File> download(Attachment a) async {
    final box = cipher;
    final tok = token;
    final host = server;
    if (box == null || tok == null || host == null) throw SyncException('未登录');
    final job = Transfer(name: a.name, total: a.size);
    transfer.value = job;
    final sealed = File('${supportDir.path}${Platform.pathSeparator}dl-${a.id}.bin');
    final safe = a.name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    final dest = File('${supportDir.path}${Platform.pathSeparator}$safe');
    try {
      await api.downloadTo(host, tok, a.id, sealed, onProgress: (d, t) {
        job.done = d;
        job.total = t;
        transfer.value = job;
      });
      job.waiting = true;
      transfer.value = job;
      final sink = dest.openWrite();
      await box.openTo(sealed.openRead(), sink.add);
      await sink.close();
      transfer.value = null;
      return dest;
    } catch (e) {
      job.error = '$e';
      transfer.value = job;
      rethrow;
    } finally {
      if (await sealed.exists()) await sealed.delete();
    }
  }

  void dismissTransfer() => transfer.value = null;

  Future<void> sync() async {
    final box = cipher;
    final tok = token;
    final host = server;
    if (box == null || tok == null || host == null) return;
    try {
      final remote = await api.notes(host, tok);
      await _merge(remote);
      await _connect(host, tok);
      error = null;
    } on SyncException catch (e) {
      error = e.message;
    } catch (e) {
      error = '同步失败：$e';
    }
    notifyListeners();
  }

  Future<void> _merge(List<RemoteNote> remote) async {
    final box = cipher;
    if (box == null) return;
    final seen = <String>{};
    for (final r in remote) {
      seen.add(r.id);
      Note? local;
      for (final n in notes) {
        if (n.id == r.id) local = n;
      }
      if (local != null && local.dirty && local.updatedAt >= r.updatedAt) {
        await push(local);
        continue;
      }
      if (local != null && local.updatedAt > r.updatedAt) continue;
      try {
        final plain = await box.openText(r.nonce, r.ciphertext);
        final next = Note.decode(r.id, plain, r.updatedAt);
        if (local == null) {
          notes.add(next);
        } else {
          local.title = next.title;
          local.body = next.body;
          local.files
            ..clear()
            ..addAll(next.files);
          local.updatedAt = next.updatedAt;
          local.dirty = false;
        }
      } on SyncException {
        if (local == null) notes.add(Note(id: r.id, title: '无法解密', updatedAt: r.updatedAt));
      }
    }
    notes.removeWhere((n) => !n.dirty && !seen.contains(n.id));
    notes.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    await _saveCache();
  }

  Future<void> _connect(String host, String tok) async {
    await _sub?.cancel();
    await _socket?.sink.close();
    final socket = await WebSocket.connect(SyncApi.socketUri(host, tok).toString());
    _socket = IOWebSocketChannel(socket);
    _sub = _socket!.stream.listen((event) {
      unawaited(_onSocket(event));
    }, onError: (Object e) {
      error = '连接中断：$e';
      notifyListeners();
    }, onDone: () {
      if (!_closed && signedIn) {
        Future<void>.delayed(const Duration(seconds: 2), sync);
      }
    });
  }

  Future<void> _onSocket(Object? event) async {
    final text = event is String ? event : utf8.decode(event is List<int> ? event : utf8.encode('$event'));
    final j = jsonDecode(text);
    if (j is! Map) return;
    if (j['op'] == 'snapshot' && j['notes'] is List) {
      final list = [
        for (final e in j['notes'] as List)
          if (e is Map) RemoteNote.fromJson(Map<String, dynamic>.from(e)),
      ];
      await _merge(list);
      notifyListeners();
    } else if (j['op'] == 'put' && j['note'] is Map) {
      await _merge([RemoteNote.fromJson(Map<String, dynamic>.from(j['note'] as Map))]);
      notifyListeners();
    } else if (j['op'] == 'del' && j['id'] is String) {
      notes.removeWhere((n) => n.id == j['id'] && !n.dirty);
      await _saveCache();
      notifyListeners();
    }
  }

  File _cacheFile() => File('${supportDir.path}${Platform.pathSeparator}notes.json');

  Future<void> _loadCache() async {
    final f = _cacheFile();
    if (!await f.exists()) return;
    try {
      final raw = jsonDecode(await f.readAsString());
      if (raw is List) {
        notes
          ..clear()
          ..addAll([for (final e in raw) if (e is Map) Note.fromCache(Map<String, dynamic>.from(e))]);
      }
    } catch (_) {}
  }

  Future<void> _saveCache() async {
    await supportDir.create(recursive: true);
    await _cacheFile().writeAsString(jsonEncode([for (final n in notes) n.toCache()]));
  }

  @override
  void dispose() {
    _closed = true;
    _sub?.cancel();
    _socket?.sink.close();
    transfer.dispose();
    super.dispose();
  }
}
