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
  Note({
    required this.id,
    this.title = '',
    this.body = '',
    List<Attachment>? files,
    List<String>? tags,
    required this.updatedAt,
    int? createdAt,
    this.dirty = false,
    this.pinned = false,
    this.trashed = false,
    this.folder = false,
    this.folderId,
  })  : files = files ?? [],
        tags = tags ?? [],
        createdAt = createdAt ?? updatedAt;

  final String id;
  String title;
  String body;
  final List<Attachment> files;
  final List<String> tags;
  int updatedAt;
  int createdAt;
  bool dirty;
  bool pinned;
  bool trashed;
  bool folder;
  String? folderId;

  String get heading => title.trim().isEmpty ? (folder ? '未命名文件夹' : '无标题') : title.trim();

  void copyContent(Note next) {
    title = next.title;
    body = next.body;
    files
      ..clear()
      ..addAll(next.files);
    tags
      ..clear()
      ..addAll(next.tags);
    updatedAt = next.updatedAt;
    createdAt = next.createdAt;
    pinned = next.pinned;
    trashed = next.trashed;
    folder = next.folder;
    folderId = next.folderId;
    dirty = false;
  }

  Map<String, dynamic> _payload() => {
        'title': title,
        'body': body,
        'files': [for (final f in files) {'id': f.id, 'name': f.name, 'size': f.size}],
        'tags': tags,
        'pinned': pinned,
        'trashed': trashed,
        'folder': folder,
        'folderId': folderId,
        'createdAt': createdAt,
      };

  String encode() => jsonEncode(_payload());

  static List<Attachment> _files(Object? raw) {
    final files = <Attachment>[];
    if (raw is List) {
      for (final e in raw) {
        if (e is Map && e['id'] is String) {
          files.add(Attachment(id: e['id'] as String, name: '${e['name'] ?? 'file'}', size: (e['size'] as num?)?.toInt() ?? 0));
        }
      }
    }
    return files;
  }

  static List<String> _tags(Object? raw) => raw is List ? [for (final e in raw) '$e'] : <String>[];

  static Note decode(String id, String plain, int updatedAt) {
    final j = jsonDecode(plain);
    if (j is! Map) return Note(id: id, body: plain, updatedAt: updatedAt);
    return Note(
      id: id,
      title: '${j['title'] ?? ''}',
      body: '${j['body'] ?? ''}',
      files: _files(j['files']),
      tags: _tags(j['tags']),
      updatedAt: updatedAt,
      createdAt: (j['createdAt'] as num?)?.toInt() ?? updatedAt,
      pinned: j['pinned'] == true,
      trashed: j['trashed'] == true,
      folder: j['folder'] == true,
      folderId: j['folderId'] as String?,
    );
  }

  Map<String, dynamic> toCache() => {'id': id, 'updatedAt': updatedAt, 'dirty': dirty, ..._payload()};

  factory Note.fromCache(Map<String, dynamic> j) {
    final n = Note.decode(j['id'] as String, jsonEncode(j), (j['updatedAt'] as num?)?.toInt() ?? 0);
    n.dirty = j['dirty'] == true;
    return n;
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

  List<String> get knownServers => prefs.getStringList('known_servers');

  Future<void> rememberServer(String raw) async {
    final s = normalizeServer(raw);
    if (s.isEmpty) return;
    final list = prefs.getStringList('known_servers');
    if (list.contains(s)) return;
    await prefs.setStringList('known_servers', [...list, s]);
    notifyListeners();
  }

  Future<void> forgetServer(String raw) async {
    final s = normalizeServer(raw);
    final list = prefs.getStringList('known_servers').where((e) => normalizeServer(e) != s).toList();
    await prefs.setStringList('known_servers', list);
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
      await rememberServer(s);
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

  Note create({String title = '', String body = '', String? folderId, bool folder = false}) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final n = Note(id: const Uuid().v4(), title: title, body: body, folderId: folderId, folder: folder, updatedAt: now, createdAt: now, dirty: true);
    notes.insert(0, n);
    notifyListeners();
    unawaited(_saveCache());
    unawaited(push(n));
    return n;
  }

  Note duplicate(Note source) {
    final n = create(title: source.title.trim().isEmpty ? '副本' : '${source.title} 副本', body: source.body, folderId: source.folderId);
    n.tags.addAll(source.tags);
    n.files.addAll(source.files);
    touch(n);
    return n;
  }

  void touch(Note n) {
    n.updatedAt = DateTime.now().millisecondsSinceEpoch;
    n.dirty = true;
    notes.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    notifyListeners();
    unawaited(_saveCache());
    unawaited(push(n));
  }

  void trashNote(Note n) {
    n.trashed = true;
    touch(n);
  }

  void restoreNote(Note n) {
    n.trashed = false;
    touch(n);
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
          local.copyContent(next);
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
