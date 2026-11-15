import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:share_plus/share_plus.dart';

import '../ui/ds.dart';

/// 分享出去：Android 弹系统分享面板；桌面没有统一的分享面板，改为复制到剪贴板（文件用“下载”保存）。
class ShareOut {
  /// 测试替换：记录分享内容而不调用平台
  static Future<void> Function(ShareParams p)? debugShare;

  static bool get useSystemSheet => Platform.isAndroid || Platform.isIOS;

  static Future<void> text(BuildContext context, String text, {String? subject}) async {
    if (text.trim().isEmpty) return;
    if (debugShare != null) return debugShare!(ShareParams(text: text, subject: subject));
    if (useSystemSheet) {
      await SharePlus.instance.share(ShareParams(text: text, subject: subject));
      return;
    }
    await Clipboard.setData(ClipboardData(text: text));
    if (context.mounted) showToast(context, '已复制，可粘贴到其它应用');
  }

  static Future<void> file(BuildContext context, File f, {String? name}) async {
    final x = XFile(f.path, name: name);
    if (debugShare != null) return debugShare!(ShareParams(files: [x]));
    await SharePlus.instance.share(ShareParams(files: [x], fileNameOverrides: name == null ? null : [name]));
  }
}
