import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_scope.dart';
import '../blocks/block_type.dart';
import '../blocks/builtin_types.dart';
import '../models/block.dart';
import '../ui/ds.dart';

/// 从其它应用“分享”进来的内容（Android ACTION_SEND / SEND_MULTIPLE）。
class SharedPayload {
  final String? text;
  final String? subject;
  final List<({String name, String path})> files;
  const SharedPayload({this.text, this.subject, this.files = const []});

  static SharedPayload? fromMap(Object? m) {
    if (m is! Map) return null;
    final files = <({String name, String path})>[
      for (final f in (m['files'] as List?) ?? const [])
        if (f is Map && f['path'] is String) (name: (f['name'] as String?) ?? 'shared', path: f['path'] as String),
    ];
    final text = m['text'] as String?;
    if ((text == null || text.trim().isEmpty) && files.isEmpty) return null;
    return SharedPayload(text: text, subject: m['subject'] as String?, files: files);
  }
}

class ShareReceiver {
  static const channel = MethodChannel('syncnotes/share');
  static final incoming = ValueNotifier<SharedPayload?>(null);
  static bool _init = false;

  static Future<void> init() async {
    if (_init || !Platform.isAndroid) return;
    _init = true;
    channel.setMethodCallHandler((call) async {
      if (call.method == 'shared') incoming.value = SharedPayload.fromMap(call.arguments);
    });
    try {
      incoming.value = SharedPayload.fromMap(await channel.invokeMethod<Object?>('getInitialShare'));
    } catch (_) {}
  }
}

/// 保存分享进来的内容：文字 → 消息块；文件 → 上传为文件块。
Future<void> saveShared(BuildContext context, SharedPayload p) async {
  final s = AppScope.of(context);
  final text = [if (p.subject != null && p.subject!.trim().isNotEmpty && !(p.text ?? '').contains(p.subject!)) p.subject!.trim(), ?p.text?.trim()]
      .where((e) => e.isNotEmpty)
      .join('\n');
  if (text.isNotEmpty) {
    s.sync.create(
      kind: BlockKind.message,
      title: shortTitle(text),
      payload: {'text': text},
      viewedMode: defaultViewedMode(context),
    );
    if (p.files.isEmpty) showToast(context, '已保存分享的内容');
  }
  for (final f in p.files) {
    List<int> bytes;
    try {
      bytes = await File(f.path).readAsBytes();
    } catch (_) {
      if (context.mounted) showToast(context, '无法读取 ${f.name}');
      continue;
    }
    if (!context.mounted) return;
    await uploadFileBlock(context, f.name, bytes);
    try {
      await File(f.path).delete();
    } catch (_) {}
  }
}
