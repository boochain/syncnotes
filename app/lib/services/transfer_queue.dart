import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
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
  /// 运行中的实时状态提示（如"网络波动，正在续传分片…" / "正在校验文件完整性…"），不覆盖失败原因。
  String? statusNote;
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
/// - 本地文件路径直接通过 stat 获取长度并自动启用 4 MiB 分片断点续传；
/// - 大文件下载断连/超时自动从 `.part` 断点续传并做端到端 SHA-256 校验；
/// - EMA 速率平滑 + 网络抖动自动静默续传 + 取消即时断连。
class TransferQueue extends ChangeNotifier {
  TransferQueue({required this.api, required this.settings});

  final AuthApi api;
  final Settings settings;
  static const maxUploadConcurrent = 1;
  static const maxDownloadConcurrent = 2;
  static const maxAutoRetries = 3;
  static const _maxDownloadResumeRetries = 8;

  /// 字节进度。侧边栏不听这个，只听任务状态。
  final ValueNotifier<int> progress = ValueNotifier<int>(0);

  final List<TransferJob> jobs = [];
  int _seq = 0;
  int _runningUp = 0;
  int _runningDown = 0;

  int get activeCount =>
      jobs.where((j) => j.status == TransferStatus.queued || j.status == TransferStatus.running).length;

  /// 等待队列里正在进行的上传/下载结束。若有失败的任务则抛出原因。
  Future<void> waitIdle({Duration timeout = const Duration(seconds: 120)}) async {
    bool busy() => jobs.any((j) => j.status == TransferStatus.queued || j.status == TransferStatus.running);
    if (!busy()) {
      _throwIfFailed();
      return;
    }
    final c = Completer<void>();
    late VoidCallback l;
    final t = Timer(timeout, () {
      if (!c.isCompleted) c.completeError(AuthException('文件传输超时，请检查网络后重试'));
    });
    l = () {
      if (busy() || c.isCompleted) return;
      t.cancel();
      removeListener(l);
      c.complete();
    };
    addListener(l);
    try {
      await c.future;
    } finally {
      t.cancel();
      removeListener(l);
    }
    _throwIfFailed();
  }

  void _throwIfFailed() {
    final failed = jobs.where((j) => j.status == TransferStatus.failed).toList();
    if (failed.isEmpty) return;
    throw AuthException(failed.map((j) => '${j.name}：${j.error ?? '失败'}').join('；'));
  }

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
      j.statusNote = null;
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
    j.statusNote = null;
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
      } else if (dt >= 2500) {
        // 超过 2.5 秒无新字节，让速率平滑回落避免误导
        j.speed = j.speed * 0.5;
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
    if (s.contains('已取消') ||
        s.contains('未登录') ||
        s.contains('413') ||
        s.contains('文件过大') ||
        s.contains('文件不存在') ||
        s.contains('无效令牌') ||
        s.contains('校验失败')) {
      return false;
    }
    return s.contains('连接') ||
        s.contains('timeout') ||
        s.contains('超时') ||
        s.contains('reset') ||
        s.contains('broken pipe') ||
        s.contains('没有回复') ||
        s.contains('socket');
  }

  static String _hex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

  Future<String> _sha256File(File file) async {
    final sink = Sha256().toSync().newHashSink();
    var chunks = 0;
    await for (final part in file.openRead()) {
      sink.add(part);
      chunks++;
      if (chunks % 16 == 0) {
        await Future<void>.delayed(Duration.zero);
      }
    }
    sink.close();
    return _hex(sink.hashSync().bytes);
  }

  Future<void> _downloadToFileResumable(TransferJob j, String server, String token) async {
    final dest = j.dest!;
    final part = File('$dest.part');
    await part.parent.create(recursive: true);

    var downloaded = 0;
    var serverTotal = j.total;
    var serverSha = '';
    var usedResume = false;
    var consecutiveErrors = 0;

    final raf = await part.open(mode: FileMode.write);
    try {
      while (true) {
        if (j.cancelRequested) throw AuthException('已取消');
        final startOffset = downloaded;
        await raf.setPosition(startOffset);
        var wroteInAttempt = 0;
        try {
          await api.downloadStream(
            server,
            token,
            j.fileId!,
            (plain) async {
              await raf.writeFrom(plain);
              downloaded += plain.length;
              wroteInAttempt += plain.length;
            },
            offset: startOffset,
            onHeader: (total, sha, serverOffset) {
              if (total > 0) serverTotal = total;
              if (sha.isNotEmpty) serverSha = sha;
              // 若旧版服务器忽略了 offset 并从 0 开始下发，则重置本地写入指针到 0
              if (startOffset > 0 && serverOffset == 0) {
                downloaded = 0;
                raf.setPositionSync(0);
                raf.truncateSync(0);
              }
            },
            onProgress: (d, t) {
              if (j.statusNote != null && wroteInAttempt > 0) {
                j.statusNote = null;
              }
              _progress(j, d, t);
            },
            isCanceled: () => j.cancelRequested,
            expectSha256: startOffset == 0 ? j.sha256 : null,
            onCancelReady: (abort) => j.abortHook = abort,
          );
          break;
        } catch (e) {
          j.abortHook = null;
          if (j.cancelRequested || !_isTransientError(e)) rethrow;
          if (wroteInAttempt > 0) {
            // 本轮有实际字节推进，重置连续失败计数，允许长传输多次抗抖动续传
            consecutiveErrors = 0;
          }
          consecutiveErrors++;
          if (consecutiveErrors > _maxDownloadResumeRetries) rethrow;
          usedResume = true;
          j.speed = 0;
          j.sampleAt = DateTime.now();
          j.sampleDone = downloaded;
          j.statusNote = '网络波动，正在断点续传 ($consecutiveErrors/$_maxDownloadResumeRetries)…';
          progress.value++;
          final waitSec = consecutiveErrors.clamp(1, 5);
          await Future<void>.delayed(Duration(seconds: waitSec));
        }
      }
      await raf.flush();
    } finally {
      await raf.close();
    }

    if (j.cancelRequested) throw AuthException('已取消');
    if (serverTotal > 0 && downloaded != serverTotal) {
      throw AuthException('文件长度不符（$downloaded / $serverTotal）');
    }

    // 触发过断点续传时，对拼装完成的 `.part` 做一次端到端 SHA-256 校验
    final expect = (j.sha256 != null && j.sha256!.isNotEmpty) ? j.sha256! : serverSha;
    if (usedResume && expect.isNotEmpty) {
      j.confirming = true;
      j.statusNote = '正在校验文件完整性…';
      progress.value++;
      final actual = await _sha256File(part);
      if (actual != expect) {
        throw AuthException('文件校验失败');
      }
    }

    final finalFile = File(dest);
    if (await finalFile.exists()) await finalFile.delete();
    await part.rename(dest);
    j.confirming = false;
    j.statusNote = null;
    j.done = downloaded;
    if (serverTotal > 0) j.total = serverTotal;
    j.status = TransferStatus.done;
    j.speed = 0;
    if (!j.completer.isCompleted) j.completer.complete(dest);
  }

  Future<void> _runOnce(TransferJob j, String server, String token) async {
    j.done = 0;
    j.speed = 0;
    j.confirming = false;
    j.statusNote = null;
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
        filePath: j.path,
        source: (j.bytes != null || j.path != null) ? null : j.open?.call(),
        total: j.total,
        onProgress: (d, t) => _progress(j, d, t),
        onWaiting: () {
          j.confirming = true;
          progress.value++;
        },
        onStatus: (note) {
          j.statusNote = note;
          if (note != null) {
            j.speed = 0;
            j.sampleAt = DateTime.now();
            j.sampleDone = j.done;
          }
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
      j.statusNote = null;
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
      j.statusNote = null;
      j.status = TransferStatus.done;
      j.speed = 0;
      if (!j.completer.isCompleted) j.completer.complete('');
    } else {
      await _downloadToFileResumable(j, server, token);
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
          j.statusNote = '网络波动，正在自动重试 (${j.attempts}/$maxAutoRetries)…';
          j.speed = 0;
          progress.value++;
          await Future<void>.delayed(Duration(seconds: j.attempts));
          if (j.cancelRequested) throw AuthException('已取消');
          j.statusNote = null;
        }
      }
    } catch (e) {
      final canceled = j.cancelRequested || '$e'.contains('已取消');
      j.status = canceled ? TransferStatus.canceled : TransferStatus.failed;
      j.confirming = false;
      j.statusNote = null;
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
