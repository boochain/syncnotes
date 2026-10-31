import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'settings_store.dart';
import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/io.dart';

import 'api.dart';
import 'crypto.dart';
import 'library.dart';

class Revision {
  final int at;
  final String title;
  final String body;
  const Revision({required this.at, required this.title, required this.body});
}

class NoteComment {
  final String id;
  final String text;
  final int at;
  const NoteComment({required this.id, required this.text, required this.at});
}

class Attachment {
  final String id;
  final String name;
  final int size;
  const Attachment({required this.id, required this.name, required this.size});
}

class NoteConflict {
  final String id;
  final String localTitle;
  final String localBody;
  final String remoteTitle;
  final String remoteBody;
  const NoteConflict({required this.id, required this.localTitle, required this.localBody, required this.remoteTitle, required this.remoteBody});
}

List<Revision> rememberRevision(List<Revision> history, {required int at, required String title, required String body, int gapMs = 60000, int cap = 15}) {
  if (history.isNotEmpty && history.last.title == title && history.last.body == body) return history;
  if (history.isNotEmpty && at - history.last.at < gapMs) return history;
  final next = [...history, Revision(at: at, title: title, body: body)];
  if (next.length <= cap) return next;
  return next.sublist(next.length - cap);
}

String pinDigest(String pin) {
  var h = 2166136261;
  for (final c in utf8.encode('syncnotes-pin:$pin')) {
    h ^= c;
    h = (h * 16777619) & 0x7fffffff;
  }
  return h.toRadixString(16);
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
    this.icon = '',
    this.order = 0,
    this.color = '',
    this.remindAt,
    this.smart = false,
    this.smartQuery = '',
    List<Revision>? history,
    List<NoteComment>? comments,
  })  : files = files ?? [],
        tags = tags ?? [],
        history = history ?? [],
        comments = comments ?? [],
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
  String icon;
  int order;
  String color;
  int? remindAt;
  bool smart;
  String smartQuery;
  List<Revision> history;
  final List<NoteComment> comments;

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
    icon = next.icon;
    order = next.order;
    color = next.color;
    remindAt = next.remindAt;
    smart = next.smart;
    smartQuery = next.smartQuery;
    history = [...next.history];
    comments
      ..clear()
      ..addAll(next.comments);
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
        'icon': icon,
        'order': order,
        'color': color,
        'remindAt': remindAt,
        'smart': smart,
        'smartQuery': smartQuery,
        'history': [for (final h in history) {'at': h.at, 'title': h.title, 'body': h.body}],
        'comments': [for (final c in comments) {'id': c.id, 'text': c.text, 'at': c.at}],
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

  static List<Revision> _history(Object? raw) {
    if (raw is! List) return [];
    return [
      for (final e in raw)
        if (e is Map) Revision(at: (e['at'] as num?)?.toInt() ?? 0, title: '${e['title'] ?? ''}', body: '${e['body'] ?? ''}'),
    ];
  }

  static List<NoteComment> _comments(Object? raw) {
    if (raw is! List) return [];
    return [
      for (final e in raw)
        if (e is Map && e['id'] is String) NoteComment(id: e['id'] as String, text: '${e['text'] ?? ''}', at: (e['at'] as num?)?.toInt() ?? 0),
    ];
  }

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
      icon: '${j['icon'] ?? ''}',
      order: (j['order'] as num?)?.toInt() ?? 0,
      color: '${j['color'] ?? ''}',
      remindAt: (j['remindAt'] as num?)?.toInt(),
      smart: j['smart'] == true,
      smartQuery: '${j['smartQuery'] ?? ''}',
      history: _history(j['history']),
      comments: _comments(j['comments']),
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
  final conflicts = <NoteConflict>[];
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

  bool get closeToTray => prefs.getBool('close_to_tray') ?? true;
  set closeToTray(bool v) {
    prefs.setBool('close_to_tray', v);
    notifyListeners();
  }

  String get backdrop => prefs.getString('backdrop') ?? 'default';
  set backdrop(String v) {
    prefs.setString('backdrop', v);
    notifyListeners();
  }

  double get surfaceOpacity {
    final raw = double.tryParse(prefs.getString('surface_opacity') ?? '') ?? 1;
    if (raw < 0.72) return 0.72;
    if (raw > 1) return 1;
    return raw;
  }

  set surfaceOpacity(double v) {
    final next = v < 0.72 ? 0.72 : (v > 1 ? 1 : v);
    prefs.setString('surface_opacity', next.toStringAsFixed(2));
    notifyListeners();
  }

  double get textScale {
    final raw = double.tryParse(prefs.getString('text_scale') ?? '') ?? 1;
    if (raw < 1.05) return 1;
    if (raw < 1.2) return 1.15;
    return 1.3;
  }

  set textScale(double v) {
    prefs.setString('text_scale', '$v');
    notifyListeners();
  }

  String? pendingFingerprint;
  int queued = 0;
  final _jobs = <Future<void> Function()>[];
  var _draining = false;

  Map<String, String> _prints() {
    final raw = prefs.getString('fingerprints');
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) return {for (final e in decoded.entries) '${e.key}': '${e.value}'};
    } catch (_) {}
    return {};
  }

  Future<void> _noteFingerprint(String host) async {
    String? id;
    try {
      id = await api.serverFingerprint(host);
    } catch (_) {
      return;
    }
    final status = fingerprintStatus(known: _prints()[host], current: id);
    if (status == 'new' && id != null) {
      final next = _prints()..[host] = id;
      await prefs.setString('fingerprints', jsonEncode(next));
      pendingFingerprint = null;
    } else if (status == 'changed') {
      pendingFingerprint = id;
      error = '服务器指纹变了。指纹不是密码，只用来确认还是不是原来那台。';
    } else {
      pendingFingerprint = null;
    }
    notifyListeners();
  }

  Future<void> acceptFingerprint() async {
    final host = server;
    final id = pendingFingerprint;
    if (host == null || id == null) return;
    final next = _prints()..[host] = id;
    await prefs.setString('fingerprints', jsonEncode(next));
    pendingFingerprint = null;
    if (error != null && error!.contains('指纹')) error = null;
    notifyListeners();
  }

  String? fingerprintFor(String host) => _prints()[normalizeServer(host)];

  Future<int> resendLocal() async {
    var sent = 0;
    for (final n in notes.toList()) {
      n.dirty = true;
      await push(n);
      if (!n.dirty) sent++;
    }
    await sync();
    return sent;
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
      await _noteFingerprint(s);
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

  void persistOrders(Iterable<Note> visible) {
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final n in visible) {
      n.updatedAt = now;
      n.dirty = true;
      unawaited(push(n));
    }
    unawaited(_saveCache());
    notifyListeners();
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
    final changed = (body != null && body != n.body) || (title != null && title != n.title);
    if (changed) {
      n.history = rememberRevision(n.history, at: n.updatedAt, title: n.title, body: n.body);
    }
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

  Future<Attachment?> attach(Note n, String name, Stream<List<int>> Function() open, int size) {
    final done = Completer<Attachment?>();
    _jobs.add(() async {
      try {
        done.complete(await _attachNow(n, name, open, size));
      } catch (e) {
        if (!done.isCompleted) done.completeError(e);
      }
    });
    queued = _jobs.length;
    notifyListeners();
    unawaited(_drain());
    return done.future;
  }

  Future<void> _drain() async {
    if (_draining) return;
    _draining = true;
    try {
      while (_jobs.isNotEmpty) {
        final job = _jobs.removeAt(0);
        queued = _jobs.length;
        notifyListeners();
        await job();
      }
    } finally {
      _draining = false;
      if (_jobs.isNotEmpty) unawaited(_drain());
    }
  }

  Future<Attachment?> _attachNow(Note n, String name, Stream<List<int>> Function() open, int size) async {
    final box = cipher;
    final tok = token;
    final host = server;
    if (box == null || tok == null || host == null) return null;
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
      return n.files.last;
    } on SyncException catch (e) {
      job.error = e.message;
      transfer.value = job;
    } catch (e) {
      job.error = '上传失败：$e';
      transfer.value = job;
    } finally {
      if (await tmp.exists()) await tmp.delete();
    }
    return null;
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

  bool syncing = false;
  bool live = false;
  int? lastSyncAt;

  void dismissTransfer() => transfer.value = null;

  void clearError() {
    error = null;
    notifyListeners();
  }

  void removeFile(Note n, String fileId) {
    n.files.removeWhere((f) => f.id == fileId);
    touch(n);
  }

  bool get hasPin => (prefs.getString('pin_hash') ?? '').isNotEmpty;
  bool locked = false;

  Future<void> setPin(String pin) async {
    await prefs.setString('pin_hash', pinDigest(pin));
    locked = false;
    notifyListeners();
  }

  Future<void> clearPin(String pin) async {
    if (pinDigest(pin) != prefs.getString('pin_hash')) throw SyncException('应用锁密码不对');
    await prefs.remove('pin_hash');
    locked = false;
    notifyListeners();
  }

  bool tryUnlock(String pin) {
    if (pinDigest(pin) != prefs.getString('pin_hash')) return false;
    locked = false;
    notifyListeners();
    return true;
  }

  void lockIfNeeded() {
    if (hasPin && signedIn && !locked) {
      locked = true;
      notifyListeners();
    }
  }

  void resolveConflict(String id, String choice) {
    Note? local;
    for (final n in notes) {
      if (n.id == id) local = n;
    }
    final hit = conflicts.where((c) => c.id == id).toList();
    if (local == null || hit.isEmpty) {
      conflicts.removeWhere((c) => c.id == id);
      notifyListeners();
      return;
    }
    final c = hit.first;
    if (choice == 'remote') {
      local.title = c.remoteTitle;
      local.body = c.remoteBody;
      touch(local);
    } else if (choice == 'both') {
      create(title: '${c.localTitle}（这台设备）', body: c.localBody, folderId: local.folderId);
      local.title = c.remoteTitle;
      local.body = c.remoteBody;
      touch(local);
    } else {
      touch(local);
    }
    conflicts.removeWhere((e) => e.id == id);
    notifyListeners();
  }

  Future<String> shareNote(Note n, String passphrase) async {
    final host = server;
    final tok = token;
    if (host == null || tok == null) throw SyncException('未登录');
    if (passphrase.length < 6) throw SyncException('分享密码至少 6 位，告诉对方时不要用你的登录密码');
    final box = await NoteCipher.fromPassword(passphrase);
    final plain = jsonEncode({
      'title': n.title,
      'body': n.body,
      'comments': [for (final c in n.comments) {'id': c.id, 'text': c.text, 'at': c.at}],
    });
    final sealed = await box.sealText(plain);
    final id = const Uuid().v4();
    await api.putShare(host, tok, id: id, nonce: sealed.nonce, ciphertext: sealed.ciphertext);
    return id;
  }

  Future<Note> importShare(String id, String passphrase) async {
    final host = server;
    if (host == null) throw SyncException('未登录');
    final sealed = await api.getShare(host, id.trim());
    final box = await NoteCipher.fromPassword(passphrase);
    final plain = await box.openText(sealed.nonce, sealed.ciphertext);
    final j = jsonDecode(plain);
    if (j is! Map) throw SyncException('分享内容打不开');
    final note = create(title: '${j['title'] ?? ''}', body: '${j['body'] ?? ''}');
    final comments = Note._comments(j['comments']);
    note.comments.addAll(comments);
    touch(note);
    return note;
  }

  Future<void> changePassword(String current, String next) async {
    final box = cipher;
    final tok = token;
    final host = server;
    if (box == null || tok == null || host == null) throw SyncException('未登录');
    if (next.length < 8) throw SyncException('新密码至少 8 位');
    final oldBox = await NoteCipher.fromPassword(current);
    final oldBytes = await oldBox.extract();
    final curBytes = await box.extract();
    if (oldBytes.length != curBytes.length) throw SyncException('现在的密码不对');
    for (var i = 0; i < oldBytes.length; i++) {
      if (oldBytes[i] != curBytes[i]) throw SyncException('现在的密码不对');
    }
    final fresh = await NoteCipher.fromPassword(next);
    final previous = [for (final n in notes) (n.id, n.encode(), [...n.files])];
    try {
      for (final n in notes) {
        final replaced = <Attachment>[];
        for (final file in n.files) {
          final plain = await _downloadPlain(oldBox, host, tok, file);
          final sealed = await fresh.sealBytes(plain);
          final tmp = File('${supportDir.path}${Platform.pathSeparator}rekey-${file.id}.bin');
          await tmp.writeAsBytes(sealed, flush: true);
          final up = await api.uploadFile(host, tok, tmp, name: file.name);
          if (await tmp.exists()) await tmp.delete();
          replaced.add(Attachment(id: up.id, name: up.name, size: up.size));
        }
        n.files
          ..clear()
          ..addAll(replaced);
        n.updatedAt = DateTime.now().millisecondsSinceEpoch;
        final sealedNote = await fresh.sealText(n.encode());
        await api.putNote(host, tok, RemoteNote(id: n.id, updatedAt: n.updatedAt, nonce: sealedNote.nonce, ciphertext: sealedNote.ciphertext));
        n.dirty = false;
      }
      await api.changePassword(host, tok, current, next);
      cipher = fresh;
      await prefs.setString('key', base64Encode(await fresh.extract()));
      await _saveCache();
      notifyListeners();
    } catch (e) {
      for (final snap in previous) {
        Note? n;
        for (final item in notes) {
          if (item.id == snap.$1) n = item;
        }
        if (n == null) continue;
        final restored = Note.decode(n.id, snap.$2, n.updatedAt);
        n.copyContent(restored);
        n.dirty = true;
        n.files
          ..clear()
          ..addAll(snap.$3);
        await push(n);
      }
      throw SyncException('密码没有改成。笔记已尽量恢复成旧密码。$e');
    }
  }

  Future<List<int>> _downloadPlain(NoteCipher box, String host, String tok, Attachment file) async {
    final sealed = File('${supportDir.path}${Platform.pathSeparator}rekey-dl-${file.id}.bin');
    try {
      await api.downloadTo(host, tok, file.id, sealed);
      final out = BytesBuilder(copy: false);
      await box.openTo(sealed.openRead(), out.add);
      return out.toBytes();
    } finally {
      if (await sealed.exists()) await sealed.delete();
    }
  }

  void addComment(Note n, String text) {
    final t = text.trim();
    if (t.isEmpty) return;
    n.comments.add(NoteComment(id: const Uuid().v4(), text: t, at: DateTime.now().millisecondsSinceEpoch));
    touch(n);
  }

  void restoreRevision(Note n, Revision revision) {
    n.history = rememberRevision(n.history, at: n.updatedAt, title: n.title, body: n.body, gapMs: 0);
    n.title = revision.title;
    n.body = revision.body;
    touch(n);
  }

  Future<File> exportNotesFile() async {
    final f = File('${supportDir.path}${Platform.pathSeparator}syncnotes-export.md');
    final text = [
      for (final n in notes)
        if (!n.folder && !n.trashed) '# ${n.heading}\n\n${n.body}\n',
    ].join('\n---\n\n');
    await f.writeAsString(text);
    return f;
  }

  Future<void> sync() async {
    final box = cipher;
    final tok = token;
    final host = server;
    if (box == null || tok == null || host == null) return;
    syncing = true;
    notifyListeners();
    try {
      final remote = await api.notes(host, tok);
      await _merge(remote);
      await _connect(host, tok);
      error = null;
      live = true;
      lastSyncAt = DateTime.now().millisecondsSinceEpoch;
    } on SyncException catch (e) {
      error = e.message;
      live = false;
    } catch (e) {
      error = '同步失败：$e';
      live = false;
    } finally {
      syncing = false;
      notifyListeners();
    }
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
      if (local != null && local.dirty && local.updatedAt < r.updatedAt) {
        try {
          final plain = await box.openText(r.nonce, r.ciphertext);
          final remoteNote = Note.decode(r.id, plain, r.updatedAt);
          if (remoteNote.title != local.title || remoteNote.body != local.body) {
            conflicts.removeWhere((c) => c.id == local!.id);
            conflicts.add(NoteConflict(id: local.id, localTitle: local.title, localBody: local.body, remoteTitle: remoteNote.title, remoteBody: remoteNote.body));
            continue;
          }
        } on SyncException {
          continue;
        }
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
      live = false;
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
