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
  /// 字节已经交给网络，在等服务器确认。这时候不能显示 100%。
  bool confirming = false;
  Uint8List? mem;
  DateTime sampleAt = DateTime.now();
  int sampleDone = 0;
  int attempts = 0;
  VoidCallback? abortHook;
  Completer<String> completer = Completer<String>();

  double get fraction => total <= 0 ? 0 : (done / total).clamp(0.0, 1.0);
}

/// 内存里的双通道上传/下载队列：
/// - 上传与下载独立并发（1 路上传 + 2 路下载），大文件上传不阻塞图片预览与附件下载；
/// - 本地文件路径直接通过 stat 获取长度，避免全量预读；
/// - EMA 速率平滑 + 网络抖动自动静默重试（最多 2 次）+ 取消即时断连。
class TransferQueue extends ChangeNotifier {
  TransferQueue({required this.api, required this.settings});

  final AuthApi api;
  final Settings settings;
  static const maxUploadConcurrent = 1;
  static const maxDownloadConcurrent = 2;
  static const maxAutoRetries = 2;

  /// 字节进度。侧边栏不听这个，只听任务状态。
  final ValueNotifier<int> progress = ValueNotifier<int>(0);

  final List<TransferJob> jobs = [];
  int _seq = 0;
  int _runningUp = 0;
  int _runningDown = 0;

  int get activeCount =>
      jobs.where((j) => j.status == TransferStatus.queued || j.status == TransferStatus.running).length;

  TransferJob? get current {
    for (final j in jobs) {
      if (j.status == TransferStatus.running) return j;
    }
    for (final j in jobs) {
      if (j.status == TransferStatus.queued) return j;
    }
    for (var i = jobs.length - 1; i >= 0; i--) {
      if (jobs[i].status == TransferStatus.failed) return jobs[i];
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
    if (j.status == TransferStatus.running) {
      j.cancelRequested = true;
      try {
        j.abortHook?.call();
      } catch (_) {}
    }
  }

  void retry(String id) {
    final j = _byId(id);
    if (j == null) return;
    if (j.status != TransferStatus.failed && j.status != TransferStatus.canceled) return;
    j.status = TransferStatus.queued;
    j.done = 0;
    j.speed = 0;
    j.error = null;
    j.attempts = 0;
    j.cancelRequested = false;
    j.confirming = false;
    j.sampleDone = 0;
    j.abortHook = null;
    j.completer = Completer<String>();
    unawaited(j.completer.future.catchError((Object _) => ''));
    notifyListeners();
    _pump();
  }

  void dismiss(String id) {
    final j = _byId(id);
    if (j == null) return;
    if (j.status == TransferStatus.running || j.status == TransferStatus.queued) return;
    jobs.remove(j);
    notifyListeners();
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
    while (_runningUp < maxUploadConcurrent) {
      TransferJob? next;
      for (final j in jobs) {
        if (j.dir == TransferDir.up && j.status == TransferStatus.queued) {
          next = j;
          break;
        }
      }
      if (next == null) break;
      _runningUp++;
      final job = next;
      unawaited(_run(job).whenComplete(() {
        _runningUp--;
        _pump();
      }));
    }
    while (_runningDown < maxDownloadConcurrent) {
      TransferJob? next;
      for (final j in jobs) {
        if (j.dir == TransferDir.down && j.status == TransferStatus.queued) {
          next = j;
          break;
        }
      }
      if (next == null) break;
      _runningDown++;
      final job = next;
      unawaited(_run(job).whenComplete(() {
        _runningDown--;
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
      if (db > 0) {
        final inst = db * 1000 / dt;
        // EMA 指数滑动平均，消除速率与 ETA 抖动
        j.speed = j.speed <= 0 ? inst : (j.speed * 0.65 + inst * 0.35);
      }
      j.sampleAt = now;
      j.sampleDone = done;
    }
    if (dt >= 250 || (j.total > 0 && done >= j.total)) {
      progress.value++;
    }
  }

  static bool _isTransientError(Object e) {
    final s = '$e'.toLowerCase();
    if (s.contains('已取消') || s.contains('未登录') || s.contains('413') || s.contains('文件过大') || s.contains('文件不存在') || s.contains('无效令牌') || s.contains('校验失败')) {
      return false;
    }
    return s.contains('连接') || s.contains('timeout') || s.contains('超时') || s.contains('reset') || s.contains('broken pipe') || s.contains('没有回复');
  }

  Future<void> _runOnce(TransferJob j, String server, String token) async {
    j.done = 0;
    j.speed = 0;
    j.confirming = false;
    j.sampleAt = DateTime.now();
    j.sampleDone = 0;
    j.abortHook = null;

    if (j.dir == TransferDir.up) {
      if (j.bytes != null) {
        j.total = j.bytes!.length;
      } else if (j.total <= 0 && j.path != null) {
        // 优先用系统 stat 直接获取文件长度，避免整文件预读一遍
        final f = File(j.path!);
        if (await f.exists()) {
          j.total = await f.length();
        }
      } else if (j.total <= 0 && j.open != null) {
        final probe = j.open!.call();
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
        onWaiting: () {
          j.confirming = true;
          progress.value++;
        },
        isCanceled: () => j.cancelRequested,
        onCancelReady: (abort) => j.abortHook = abort,
      );
      j.fileId = up.id;
      j.sha256 = up.sha256;
      j.done = up.size;
      j.total = up.size;
      j.confirming = false;
      j.status = TransferStatus.done;
      j.speed = 0;
      try {
        j.onSuccess?.call(up.id, up.sha256, up.size);
      } catch (_) {}
      if (!j.completer.isCompleted) j.completer.complete(up.id);
    } else if (j.keepBytes) {
      final b = BytesBuilder(copy: false);
      await api.downloadStream(
        server,
        token,
        j.fileId!,
        (plain) async {
          b.add(plain);
        },
        onProgress: (d, t) => _progress(j, d, t),
        isCanceled: () => j.cancelRequested,
        expectSha256: j.sha256,
        onCancelReady: (abort) => j.abortHook = abort,
      );
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
        await api.downloadStream(
          server,
          token,
          j.fileId!,
          (plain) async {
            await raf.writeFrom(plain);
          },
          onProgress: (d, t) => _progress(j, d, t),
          isCanceled: () => j.cancelRequested,
          expectSha256: j.sha256,
          onCancelReady: (abort) => j.abortHook = abort,
        );
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
  }

  Future<void> _run(TransferJob j) async {
    j.status = TransferStatus.running;
    notifyListeners();
    try {
      final server = settings.server;
      final token = settings.token;
      if (server == null || token == null) throw AuthException('未登录');
      while (true) {
        try {
          await _runOnce(j, server, token);
          break;
        } catch (e) {
          j.abortHook = null;
          if (j.cancelRequested || !_isTransientError(e) || j.attempts >= maxAutoRetries) {
            rethrow;
          }
          j.attempts++;
          j.error = '网络波动，正在自动重试 (${j.attempts}/$maxAutoRetries)…';
          progress.value++;
          await Future<void>.delayed(Duration(seconds: j.attempts));
          if (j.cancelRequested) throw AuthException('已取消');
          j.error = null;
        }
      }
    } catch (e) {
      final canceled = j.cancelRequested || '$e'.contains('已取消');
      j.status = canceled ? TransferStatus.canceled : TransferStatus.failed;
      j.confirming = false;
      j.error = canceled ? '已取消' : '$e';
      j.speed = 0;
      j.abortHook = null;
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
