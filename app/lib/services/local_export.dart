import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../app_scope.dart';
import '../blocks/builtin_types.dart' show safeFileName;
import '../ui/ds.dart';
import '../ui/recovery_ui.dart';
import 'data_export.dart';

/// 读取本机已下载的附件副本（下载目录 / 文档目录下的 SyncNotes 文件夹）。
Future<List<int>?> readLocalAttachment(Map<String, dynamic> block) async {
  final p = (block['payload'] as Map?) ?? const {};
  final name = safeFileName((p['name'] ?? block['id']).toString());
  final dirs = <Directory?>[];
  try {
    dirs.add(await getDownloadsDirectory());
  } catch (_) {}
  try {
    dirs.add(await getApplicationDocumentsDirectory());
  } catch (_) {}
  for (final d in dirs.whereType<Directory>()) {
    final f = File('${d.path}${Platform.pathSeparator}SyncNotes${Platform.pathSeparator}$name');
    if (await f.exists()) return f.readAsBytes();
  }
  return null;
}

/// 设置 → 导出我的数据。本地副本优先；在线时补充下载缺失的附件（失败不影响导出）。
Future<void> exportMyData(BuildContext context, AppServices s) async {
  showToast(context, '正在打包本地数据…');
  try {
    await s.sync.flush();
    final cache = await s.sync.store.load() ?? {'blocks': [], 'outbox': []};
    final st = s.settings;
    final r = await buildLocalExport(
      cache: cache,
      username: st.username,
      server: st.server,
      readAttachment: (b) async {
        final local = await readLocalAttachment(b);
        if (local != null) return local;
        final fid = (b['payload'] as Map?)?['file_id'] as String?;
        if (fid == null || st.server == null || st.token == null) return null;
        return s.api.downloadFile(st.server!, st.token!, fid).timeout(const Duration(seconds: 20));
      },
    );
    final ts = DateTime.now().toIso8601String().substring(0, 16).replaceAll(RegExp('[-:T]'), '');
    final where = await fileSaver('SyncNotes-导出-${st.username ?? 'local'}-$ts.zip', r.bytes);
    if (where != null && context.mounted) {
      showToast(context,
          '已导出 ${r.blocks} 个块（回收站 ${r.trashed}）、${r.files} 个附件${r.missingFiles > 0 ? '，${r.missingFiles} 个附件不在本机' : ''} → $where');
    }
  } catch (e) {
    if (context.mounted) showToast(context, '导出失败：$e');
  }
}
