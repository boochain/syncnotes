import 'dart:typed_data';

import '../app_scope.dart';
import 'auth_api.dart';
import 'data_export.dart';
import 'local_export.dart';
import '../sync/sync_client.dart';

/// 打包「当前能看到的」全部数据：服务器内容 + 本机尚未同步的修改和附件。
Future<LocalExportResult> buildAccountBackup(
  AppServices s, {
  void Function(String status)? onProgress,
  void Function(int done, int total)? onBytes,
}) async {
  final st = s.settings;
  await s.sync.flush();

  if (st.server != null &&
      st.token != null &&
      s.sync.state != ConnState.authError &&
      !s.sync.sealBlocked) {
    onProgress?.call('正在同步服务器最新数据…');
    final pull = await s.sync.catchUp();
    if (pull == null) {
      try {
        onProgress?.call('正在从服务器打包…');
        final zip = await s.api.downloadAccountBackup(
          st.server!,
          st.token!,
          onProgress: onBytes,
        );
        inspectBackup(zip); // 校验格式
        onProgress?.call('正在合并本机尚未同步的内容…');
        final cache = await s.sync.store.load() ?? {'blocks': [], 'outbox': []};
        final extra = <String, List<int>>{};
        final all = [
          for (final b in (cache['blocks'] as List? ?? const []))
            Map<String, dynamic>.from(b as Map),
        ];
        for (final b in all) {
          final p = (b['payload'] as Map?) ?? const {};
          final fid = (p['file_id'] ?? '').toString();
          if (fid.isEmpty) continue;
          try {
            final local = await readLocalAttachment(b);
            if (local != null) extra[fid] = local;
          } catch (_) {}
        }
        final bytes = mergeBackupWithLocal(
          serverZip: zip,
          cache: cache,
          extraFiles: extra,
          username: st.username,
          server: st.server,
        );
        final zInfo = inspectBackup(bytes);
        final outbox = (cache['outbox'] as List?) ?? const [];
        return LocalExportResult(
          Uint8List.fromList(bytes),
          zInfo.blocks,
          0,
          zInfo.files,
          0,
          outbox.length,
        );
      } on AuthException catch (e) {
        // 旧服务器没有 backup_export 时，退回本机缓存打包。
        if (!'$e'.contains('服务器版本过旧') &&
            !'$e'.contains('未知操作') &&
            !'$e'.contains('未知接口')) {
          onProgress?.call('服务器打包失败，改为打包本机已同步的数据…');
        }
      } catch (_) {
        onProgress?.call('服务器打包失败，改为打包本机已同步的数据…');
      }
    }
  }

  onProgress?.call('正在打包本机数据…');
  final cache = await s.sync.store.load() ?? {'blocks': [], 'outbox': []};
  return buildLocalExport(
    cache: cache,
    username: st.username,
    server: st.server,
    source: 'client-backup',
    formatVersion: 2,
    readAttachment: (b) async {
      final local = await readLocalAttachment(b);
      if (local != null) return local;
      final payload = (b['payload'] as Map?) ?? const {};
      final fid = payload['file_id'] as String?;
      if (fid == null || st.server == null || st.token == null) return null;
      try {
        return await s.transfers.downloadBytes(
          name: (payload['name'] ?? fid).toString(),
          fileId: fid,
        );
      } catch (_) {
        return null;
      }
    },
  );
}

class RestoreResult {
  final bool ok;
  final String? error;
  final String? safetyPath;
  final int blocks;
  final int files;
  final int tombstoned;
  const RestoreResult({
    required this.ok,
    this.error,
    this.safetyPath,
    this.blocks = 0,
    this.files = 0,
    this.tombstoned = 0,
  });
}

/// 把备份 zip 上传到当前登录账号并还原。调用方应已确认，并决定是否先保存安全备份。
Future<RestoreResult> restoreAccountBackup(
  AppServices s, {
  required List<int> zipBytes,
  void Function(String status)? onProgress,
  void Function(int done, int total)? onBytes,
  Future<String?> Function(String fileName, Uint8List bytes)? saveSafety,
}) async {
  final st = s.settings;
  if (st.server == null || st.token == null) {
    return const RestoreResult(ok: false, error: '未登录，无法恢复到服务器');
  }
  inspectBackup(zipBytes);

  String? safetyPath;
  if (saveSafety != null) {
    onProgress?.call('正在备份当前数据…');
    try {
      final safety = await buildAccountBackup(s, onProgress: onProgress);
      final ts = DateTime.now()
          .toIso8601String()
          .substring(0, 16)
          .replaceAll(RegExp('[-:T]'), '');
      safetyPath = await saveSafety(
        'SyncNotes-恢复前备份-${st.username ?? 'account'}-$ts.zip',
        safety.bytes,
      );
    } catch (e) {
      return RestoreResult(ok: false, error: '恢复前备份当前数据失败：$e');
    }
  }

  onProgress?.call('正在上传备份…');
  final UploadedFile up;
  try {
    up = await s.api.putFile(
      server: st.server!,
      token: st.token!,
      name: 'syncnotes-restore.zip',
      bytes: zipBytes,
      total: zipBytes.length,
      onProgress: onBytes,
    );
  } catch (e) {
    return RestoreResult(ok: false, error: '上传备份失败：$e', safetyPath: safetyPath);
  }

  onProgress?.call('服务器正在还原…');
  final Map<String, dynamic> res;
  try {
    res = await s.api.restoreAccount(st.server!, st.token!, up.id);
  } catch (e) {
    return RestoreResult(ok: false, error: '还原失败：$e', safetyPath: safetyPath);
  }

  onProgress?.call('正在重新同步到本机…');
  await s.sync.clearLocal(keepPending: false);
  s.sync.reconnectNow();
  final catchErr = await s.sync.catchUp(timeout: const Duration(seconds: 60));
  if (catchErr != null) {
    // 服务器已经还原成功；本机稍后会自动重连。
    return RestoreResult(
      ok: true,
      safetyPath: safetyPath,
      blocks: (res['blocks'] as num?)?.toInt() ?? 0,
      files: (res['files'] as num?)?.toInt() ?? 0,
      tombstoned: (res['tombstoned'] as num?)?.toInt() ?? 0,
      error: '服务器已还原，但本机重新同步尚未完成：$catchErr。请稍后点「立即同步」或重新连接。',
    );
  }
  return RestoreResult(
    ok: true,
    safetyPath: safetyPath,
    blocks: (res['blocks'] as num?)?.toInt() ?? 0,
    files: (res['files'] as num?)?.toInt() ?? 0,
    tombstoned: (res['tombstoned'] as num?)?.toInt() ?? 0,
  );
}
