import 'dart:io';

import 'package:cross_file/cross_file.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../blocks/builtin_types.dart';
import '../platform/desktop.dart';
import 'ds.dart';
import 'glass.dart';

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
    final pending = <Future<bool>>[];
    for (final f in files) {
      int len;
      try {
        len = await f.length();
      } catch (_) {
        if (mounted) showToast(context, '无法读取 ${f.name}（文件夹暂不支持拖放）');
        continue;
      }
      if (!mounted) return pending.length;
      final disk = f.path;
      final local = disk.isNotEmpty && !disk.startsWith('content:') && File(disk).existsSync();
      pending.add(uploadFileBlock(context, f.name, null,
          path: local ? disk : null, open: local ? null : () => f.openRead(), size: len));
    }
    if (pending.isEmpty) return 0;
    final results = await Future.wait(pending);
    return results.where((ok) => ok).length;
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
              child: Padding(
                padding: const EdgeInsets.all(Gap.m),
                child: ClipRRect(
                  key: const Key('dropOverlay'),
                  borderRadius: BorderRadius.circular(AppRadius.xl),
                  child: Frosted(
                    color: c.bg,
                    border: Border.all(color: c.accent.withValues(alpha: 0.85), width: 2),
                    child: Center(
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        Container(
                          width: 56,
                          height: 56,
                          decoration: BoxDecoration(
                            color: c.accent.withValues(alpha: 0.16),
                            shape: BoxShape.circle,
                          ),
                          child: Icon(CupertinoIcons.arrow_down_doc, size: 28, color: c.accent),
                        ),
                        const SizedBox(height: Gap.m),
                        Text('松开以上传文件', style: Theme.of(context).textTheme.titleMedium),
                      ]),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ]),
    );
  }
}
