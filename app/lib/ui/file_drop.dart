import 'package:cross_file/cross_file.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../blocks/builtin_types.dart';
import '../platform/desktop.dart';
import 'ds.dart';

/// 桌面：把文件拖进窗口 → 上传并创建文件块（Windows / Linux / macOS）。
class FileDropZone extends StatefulWidget {
  final Widget child;
  final bool enabled;
  FileDropZone({super.key, required this.child, bool? enabled}) : enabled = enabled ?? isDesktop;

  @override
  State<FileDropZone> createState() => FileDropZoneState();
}

class FileDropZoneState extends State<FileDropZone> {
  bool _over = false;

  /// 处理拖进来的文件（测试也直接调用）。返回成功上传的数量。
  Future<int> handleFiles(List<XFile> files) async {
    var n = 0;
    for (final f in files) {
      List<int> bytes;
      try {
        bytes = await f.readAsBytes();
      } catch (_) {
        if (mounted) showToast(context, '无法读取 ${f.name}（文件夹暂不支持拖放）');
        continue;
      }
      if (!mounted) return n;
      if (await uploadFileBlock(context, f.name, bytes)) n++;
    }
    return n;
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;
    final c = AppColors.of(context);
    return DropTarget(
      onDragEntered: (_) => setState(() => _over = true),
      onDragExited: (_) => setState(() => _over = false),
      onDragDone: (d) {
        setState(() => _over = false);
        handleFiles(d.files);
      },
      child: Stack(children: [
        widget.child,
        if (_over)
          Positioned.fill(
            child: IgnorePointer(
              child: Container(
                key: const Key('dropOverlay'),
                margin: const EdgeInsets.all(Gap.m),
                decoration: BoxDecoration(
                  color: c.bg.withValues(alpha: 0.85),
                  borderRadius: BorderRadius.circular(AppRadius.l),
                  border: Border.all(color: c.accent, width: 2),
                ),
                alignment: Alignment.center,
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Icon(CupertinoIcons.arrow_down_doc, size: 32, color: c.accent),
                  const SizedBox(height: Gap.m),
                  Text('松开以上传文件', style: Theme.of(context).textTheme.titleMedium),
                ]),
              ),
            ),
          ),
      ]),
    );
  }
}
