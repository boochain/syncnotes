import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import 'auth_api.dart';
import 'settings.dart';

enum TransferDir { up, down }

enum TransferStatus { queued, running, done, failed, canceled }

class TransferJob {
  TransferJob({
    required this.id,
    required this.name,
    required this.dir,
    required this.total,
    this.bytes,
    this.path,
    this.open,
    this.fileId,
    this.sha256,
    this.dest,
    this.keepBytes = false,
    this.onSuccess,
  });

  final String id;
  final String name;
  final TransferDir dir;
  final List<int>? bytes;
  final String? path;
  final Stream<List<int>> Function()? open;
  final bool keepBytes;
  final void Function(String fileId, String sha256, int size)? onSuccess;

  String? fileId;
  String? sha256;
  String? dest;
  int total;
  int done = 0;
  double speed = 0;
  TransferStatus status = TransferStatus.queued;
  String? error;
  bool cancelRequested = false;
  Uint8List? mem;
  DateTime sampleAt = DateTime.now();
  int sampleDone = 0;
  Completer<String> completer = Completer<String>();

  double get fraction => total <= 0 ? 0 : (done / total).clamp(0.0, 1.0);
}

/// 内存里的上传/下载队列。同时最多 2 个，进度按明文字节计。
class TransferQueue extends ChangeNotifier {
  TransferQueue({required this.api, required this.settings});

  final AuthApi api;
  final Settings settings;
  static const maxConcurrent = 2;

  final List<TransferJob> jobs = [];
  int _seq = 0;
  int _running = 0;
  DateTime _lastUi = DateTime.fromMillisecondsSinceEpoch(0);

  int get activeCount =>
      jobs.where((j) => j.status == TransferStatus.queued || j.status == TransferStatus.running).length;

  TransferJob? get current {
    for (final j in jobs) {
      if (j.status == TransferStatus.running) return j;
    }
    for (final j in jobs) {
      if (j.status == TransferStatus.queued) return j;
    }
    return null;
  }

  Future<UploadedFile> upload({
    required String name,
    List<int>? bytes,
    String? path,
    Stream<List<int>> Function()? open,
    int total = 0,
    void Function(String fileId, String sha256, int size)? onSuccess,
  }) {
    final job = TransferJob(
      id: 't${++_seq}',
      name: name,
      dir: TransferDir.up,
      total: total > 0 ? total : (bytes?.length ?? 0),
      bytes: bytes,
      path: path,
      open: open,
      onSuccess: onSuccess,
    );
    jobs.add(job);
    notifyListeners();
    _pump();
    return job.completer.future.then((id) => UploadedFile(id: id, sha256: job.sha256 ?? '', size: job.done));
  }

  Future<void> downloadToFile({
    required String name,
    required String fileId,
    required String dest,
    int total = 0,
    String? expectSha256,
  }) {
    for (final j in jobs) {
      if (j.dir == TransferDir.down &&
          j.fileId == fileId &&
          j.dest == dest &&
          (j.status == TransferStatus.queued || j.status == TransferStatus.running)) {
        return j.completer.future.then((_) {});
      }
    }
    final job = TransferJob(
      id: 't${++_seq}',
      name: name,
      dir: TransferDir.down,
      total: total,
      fileId: fileId,
      dest: dest,
      sha256: expectSha256,
    );
    jobs.add(job);
    notifyListeners();
    _pump();
    return job.completer.future.then((_) {});
  }

  Future<List<int>> downloadBytes({required String name, required String fileId}) async {
    final job = TransferJob(
      id: 't${++_seq}',
      name: name,
      dir: TransferDir.down,
      total: 0,
      fileId: fileId,
      keepBytes: true,
    );
    jobs.add(job);
    notifyListeners();
    _pump();
    await job.completer.future;
    return job.mem ?? Uint8List(0);
  }

  void cancel(String id) {
    final j = _byId(id);
    if (j == null) return;
    if (j.status == TransferStatus.queued) {
      j.status = TransferStatus.canceled;
      j.error = '已取消';
      if (!j.completer.isCompleted) j.completer.completeError(AuthException('已取消'));
      notifyListeners();
      return;
    }
    if (j.status == TransferStatus.running) j.cancelRequested = true;
  }

  void retry(String id) {
    final j = _byId(id);
    if (j == null) return;
    if (j.status != TransferStatus.failed && j.status != TransferStatus.canceled) return;
    j.status = TransferStatus.queued;
    j.done = 0;
    j.speed = 0;
    j.error = null;
    j.cancelRequested = false;
    j.sampleDone = 0;
    j.completer = Completer<String>();
    unawaited(j.completer.future.catchError((Object _) => ''));
    notifyListeners();
    _pump();
  }

  void clearFinished() {
    jobs.removeWhere((j) =>
        j.status == TransferStatus.done || j.status == TransferStatus.failed || j.status == TransferStatus.canceled);
    notifyListeners();
  }

  TransferJob? _byId(String id) {
    for (final j in jobs) {
      if (j.id == id) return j;
    }
    return null;
  }

  void _pump() {
    while (_running < maxConcurrent) {
      TransferJob? next;
      for (final j in jobs) {
        if (j.status == TransferStatus.queued) {
          next = j;
          break;
        }
      }
      if (next == null) return;
      _running++;
      final job = next;
      unawaited(_run(job).whenComplete(() {
        _running--;
        _pump();
      }));
    }
  }

  void _progress(TransferJob j, int done, int total) {
    if (j.cancelRequested) return;
    final now = DateTime.now();
    j.done = done;
    if (total > 0) j.total = total;
    final dt = now.difference(j.sampleAt).inMilliseconds;
    if (dt >= 200) {
      final db = done - j.sampleDone;
      j.speed = db <= 0 ? j.speed : db * 1000 / dt;
      j.sampleAt = now;
      j.sampleDone = done;
    }
    if (dt >= 200 || (j.total > 0 && done >= j.total)) {
      if (now.difference(_lastUi).inMilliseconds >= 200 || done >= j.total && j.total > 0) {
        _lastUi = now;
        notifyListeners();
      }
    }
  }

  Future<void> _run(TransferJob j) async {
    j.status = TransferStatus.running;
    j.sampleAt = DateTime.now();
    j.sampleDone = j.done;
    notifyListeners();
    try {
      final server = settings.server;
      final token = settings.token;
      if (server == null || token == null) throw AuthException('未登录');
      if (j.dir == TransferDir.up) {
        if (j.bytes != null) {
          j.total = j.bytes!.length;
        } else if (j.open != null || j.path != null) {
          // 声明长度和实际流经常对不上（尤其是 Android 的 content URI）。先数一遍，再按真实长度上传。
          final probe = j.open?.call() ?? File(j.path!).openRead();
          var n = 0;
          await for (final part in probe) {
            if (j.cancelRequested) throw AuthException('已取消');
            n += part.length;
          }
          j.total = n;
        }
        final up = await api.putFile(
          server: server,
          token: token,
          name: j.name,
          bytes: j.bytes,
          source: j.bytes != null ? null : (j.open?.call() ?? (j.path == null ? null : File(j.path!).openRead())),
          total: j.total,
          onProgress: (d, t) => _progress(j, d, t),
          isCanceled: () => j.cancelRequested,
        );
        j.fileId = up.id;
        j.sha256 = up.sha256;
        j.done = up.size;
        j.total = up.size;
        j.status = TransferStatus.done;
        j.speed = 0;
        try {
          j.onSuccess?.call(up.id, up.sha256, up.size);
        } catch (_) {}
        if (!j.completer.isCompleted) j.completer.complete(up.id);
      } else if (j.keepBytes) {
        final b = BytesBuilder(copy: false);
        await api.downloadStream(server, token, j.fileId!, (plain) async {
          b.add(plain);
        }, onProgress: (d, t) => _progress(j, d, t), isCanceled: () => j.cancelRequested, expectSha256: j.sha256);
        j.mem = b.takeBytes();
        j.done = j.mem!.length;
        j.status = TransferStatus.done;
        j.speed = 0;
        if (!j.completer.isCompleted) j.completer.complete('');
      } else {
        final dest = j.dest!;
        final part = File('$dest.part');
        await part.parent.create(recursive: true);
        final raf = await part.open(mode: FileMode.write);
        try {
          await api.downloadStream(server, token, j.fileId!, (plain) async {
            await raf.writeFrom(plain);
          }, onProgress: (d, t) => _progress(j, d, t), isCanceled: () => j.cancelRequested, expectSha256: j.sha256);
        } finally {
          await raf.close();
        }
        if (j.cancelRequested) throw AuthException('已取消');
        final finalFile = File(dest);
        if (await finalFile.exists()) await finalFile.delete();
        await part.rename(dest);
        j.status = TransferStatus.done;
        j.speed = 0;
        if (!j.completer.isCompleted) j.completer.complete(dest);
      }
    } catch (e) {
      final canceled = j.cancelRequested || '$e'.contains('已取消');
      j.status = canceled ? TransferStatus.canceled : TransferStatus.failed;
      j.error = canceled ? '已取消' : '$e';
      j.speed = 0;
      if (j.dir == TransferDir.down && j.dest != null) {
        try {
          await File('${j.dest}.part').delete();
        } catch (_) {}
      }
      if (!j.completer.isCompleted) {
        j.completer.completeError(e is AuthException ? e : AuthException('$e'));
      }
    }
    notifyListeners();
  }
}
