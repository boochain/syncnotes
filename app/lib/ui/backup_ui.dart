import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../services/backup_sync.dart';
import '../services/data_export.dart';
import 'ds.dart';
import 'recovery_ui.dart';

Future<T> _withProgress<T>(
  BuildContext context, {
  required Future<T> Function(
    void Function(String status, [double? progress]) tick,
  )
  run,
}) async {
  var status = '请稍候…';
  double? progress;
  late void Function(void Function()) setSt;
  final nav = Navigator.of(context, rootNavigator: true);
  final opened = showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (d) => PopScope(
      canPop: false,
      child: StatefulBuilder(
        builder: (c, set) {
          setSt = set;
          return AlertDialog(
            key: const Key('backupProgressDialog'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(status, style: Theme.of(c).textTheme.bodyMedium),
                const SizedBox(height: Gap.l),
                LinearProgressIndicator(value: progress),
              ],
            ),
          );
        },
      ),
    ),
  );
  await Future<void>.delayed(Duration.zero);
  void tick(String t, [double? p]) {
    status = t;
    progress = p;
    try {
      setSt(() {});
    } catch (_) {}
  }

  try {
    return await run(tick);
  } finally {
    if (nav.canPop()) nav.pop();
    await opened;
  }
}

/// 设置 → 立即同步。
Future<void> runImmediateSync(BuildContext context, AppServices s) async {
  try {
    final r = await _withProgress(
      context,
      run: (tick) async {
        tick('正在等待未完成的文件传输…');
        await s.transfers.waitIdle(timeout: const Duration(seconds: 120));
        return s.sync.syncNow(onProgress: (m) => tick(m));
      },
    );
    if (!context.mounted) return;
    if (r.ok) {
      showToast(
        context,
        r.uploaded == 0 ? '已与服务器同步，没有需要上传的修改' : '已增量上传 ${r.uploaded} 条修改',
      );
    } else {
      showToast(context, r.error ?? '同步失败');
    }
  } catch (e) {
    if (context.mounted) showToast(context, '同步失败：$e');
  }
}

/// 设置 → 备份。
Future<void> runBackup(BuildContext context, AppServices s) async {
  try {
    final r = await _withProgress(
      context,
      run: (tick) {
        return buildAccountBackup(
          s,
          onProgress: (m) => tick(m),
          onBytes: (d, t) {
            if (t > 0) tick('正在从服务器打包…', d / t);
          },
        );
      },
    );
    if (!context.mounted) return;
    final ts = DateTime.now()
        .toIso8601String()
        .substring(0, 16)
        .replaceAll(RegExp('[-:T]'), '');
    final where = await fileSaver(
      'SyncNotes-备份-${s.settings.username ?? 'local'}-$ts.zip',
      r.bytes,
    );
    if (where != null && context.mounted) {
      final pending = r.pending > 0 ? '，含 ${r.pending} 条尚未同步的修改' : '';
      showToast(context, '已备份 ${r.blocks} 个块、${r.files} 个附件$pending → $where');
    }
  } catch (e) {
    if (context.mounted) showToast(context, '备份失败：$e');
  }
}

/// 设置 → 恢复。
Future<void> runRestore(BuildContext context, AppServices s) async {
  if (s.settings.server == null || s.settings.token == null) {
    showToast(context, '请先登录后再恢复');
    return;
  }
  late final List<int> bytes;
  late final String name;
  try {
    final files = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['zip'],
    );
    if (files.isEmpty) return;
    final f = files.first;
    name = f.name;
    bytes = await f.xFile.readAsBytes();
  } catch (e) {
    if (context.mounted) showToast(context, '无法读取备份文件：$e');
    return;
  }

  final BackupInfo info;
  try {
    info = inspectBackup(bytes);
  } catch (e) {
    if (context.mounted) showToast(context, '不是有效的 SyncNotes 备份：$e');
    return;
  }
  if (!context.mounted) return;

  final who = (info.username == null || info.username!.isEmpty)
      ? '未知用户'
      : info.username!;
  final when = (info.exportedAt == null || info.exportedAt!.isEmpty)
      ? ''
      : '\n备份时间：${info.exportedAt}';
  final pending = info.pending > 0 ? '\n含 ${info.pending} 条备份时尚未同步的修改' : '';
  final ok = await confirmDanger(
    context,
    title: '用备份替换当前账号数据？',
    message:
        '将把当前登录账号（${s.settings.username ?? ''}）的内容替换为备份中的状态。\n'
        '备份来自：$who（$name），约 ${info.blocks} 个块、${info.files} 个附件。$when$pending\n\n'
        '当前账号里多出来的内容会被标记为已删除。恢复前会先自动备份当前数据。'
        '所有设备上尚未同步的修改也会被这份备份替换。密码和登录状态不变。',
    confirm: '恢复',
  );
  if (!ok || !context.mounted) return;

  // 先自动备份当前状态并让用户保存，再上传还原。
  Uint8List? safetyBytes;
  try {
    safetyBytes = (await _withProgress(
      context,
      run: (tick) {
        tick('正在备份当前数据…');
        return buildAccountBackup(s, onProgress: (m) => tick(m));
      },
    )).bytes;
  } catch (e) {
    if (context.mounted) showToast(context, '恢复前备份当前数据失败：$e');
    return;
  }
  if (!context.mounted) return;
  final ts = DateTime.now()
      .toIso8601String()
      .substring(0, 16)
      .replaceAll(RegExp('[-:T]'), '');
  var safetyPath = await fileSaver(
    'SyncNotes-恢复前备份-${s.settings.username ?? 'account'}-$ts.zip',
    safetyBytes,
  );
  if (!context.mounted) return;
  if (safetyPath == null) {
    final go = await confirmDanger(
      context,
      title: '当前数据备份没有保存',
      message: '你取消了保存恢复前的备份。服务器在还原时仍会自动保留一份近期安全备份。仍要继续恢复吗？',
      confirm: '仍然恢复',
    );
    if (!go || !context.mounted) return;
  }

  try {
    final r = await _withProgress(
      context,
      run: (tick) {
        return restoreAccountBackup(
          s,
          zipBytes: bytes,
          onProgress: (m) => tick(m),
          onBytes: (d, t) {
            if (t > 0) tick('正在上传备份…', d / t);
          },
        );
      },
    );
    if (!context.mounted) return;
    if (r.ok) {
      final safety = (safetyPath != null && safetyPath.isNotEmpty)
          ? ' 当前数据已备份到 $safetyPath。'
          : '';
      final warn = r.error != null ? ' ${r.error}' : '';
      showToast(context, '已还原 ${r.blocks} 个块、${r.files} 个附件。$safety$warn');
    } else {
      showToast(context, r.error ?? '恢复失败');
    }
  } catch (e) {
    if (context.mounted) showToast(context, '恢复失败：$e');
  }
}
