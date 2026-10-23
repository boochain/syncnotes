import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../app_scope.dart';
import '../services/transfer_queue.dart';
import 'ds.dart';

/// 服务器上的图片。先下到本地缓存再显示，不走带令牌的明文 URL。
class ServerImage extends StatefulWidget {
  final String fileId;
  final String? name;
  const ServerImage({super.key, required this.fileId, this.name});

  @override
  State<ServerImage> createState() => _ServerImageState();
}

class _ServerImageState extends State<ServerImage> {
  File? _file;
  String? _err;
  String? _dest;
  TransferQueue? _queue;
  bool _busy = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _queue ??= AppScope.of(context).transfers..addListener(_onQueue);
    if (_dest == null && !_busy) _load();
  }

  @override
  void didUpdateWidget(ServerImage old) {
    super.didUpdateWidget(old);
    if (old.fileId != widget.fileId) {
      _file = null;
      _err = null;
      _dest = null;
      _load();
    }
  }

  @override
  void dispose() {
    _queue?.removeListener(_onQueue);
    super.dispose();
  }

  void _onQueue() {
    if (!mounted || _file != null) return;
    final dest = _dest;
    if (dest != null) {
      final f = File(dest);
      if (f.existsSync() && f.lengthSync() > 0) {
        setState(() {
          _file = f;
          _err = null;
        });
        return;
      }
    }
    setState(() {});
  }

  Future<void> _load() async {
    _busy = true;
    final id = widget.fileId;
    try {
      final dir = await getApplicationSupportDirectory();
      final dest = File('${dir.path}${Platform.pathSeparator}file-cache${Platform.pathSeparator}$id');
      if (!mounted || widget.fileId != id) return;
      _dest = dest.path;
      if (await dest.exists() && await dest.length() > 0) {
        if (mounted) setState(() => _file = dest);
        return;
      }
      final q = _queue;
      if (q == null) return;
      await q.downloadToFile(name: widget.name ?? '图片', fileId: id, dest: dest.path);
      if (mounted && widget.fileId == id) setState(() { _file = dest; _err = null; });
    } catch (e) {
      if (mounted && widget.fileId == id) setState(() => _err = '$e');
    } finally {
      _busy = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final f = _file;
    if (f != null) {
      return Image.file(
        f,
        fit: BoxFit.contain,
        errorBuilder: (ctx, e, st) => _box(c, '图片加载失败'),
      );
    }
    final q = _queue;
    TransferJob? found;
    if (q != null && _dest != null) {
      for (final j in q.jobs) {
        if (j.fileId == widget.fileId && j.dest == _dest) found = j;
      }
    }
    final job = found;
    if (_err != null && (job == null || job.status == TransferStatus.failed || job.status == TransferStatus.canceled)) {
      return _box(c, '图片加载失败', onRetry: () {
        setState(() => _err = null);
        _load();
      });
    }
    final frac = job != null && job.total > 0 ? job.fraction : null;
    return Container(
      height: 120,
      color: c.fill,
      alignment: Alignment.center,
      child: SizedBox(
        width: 160,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          LinearProgressIndicator(value: frac, minHeight: 3, color: c.accent, backgroundColor: c.separator),
          const SizedBox(height: Gap.s),
          Text(job == null ? '加载中…' : '${(frac == null ? 0 : (frac * 100)).round()}%',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: c.text3)),
        ]),
      ),
    );
  }

  Widget _box(AppColors c, String text, {VoidCallback? onRetry}) {
    return Container(
      key: const Key('imageError'),
      height: 80,
      color: c.fill,
      child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        Icon(CupertinoIcons.exclamationmark_triangle, size: Sizes.iconSm, color: c.text3),
        const SizedBox(width: Gap.m),
        Text(text, style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: c.text3)),
        if (onRetry != null) ...[
          const SizedBox(width: Gap.m),
          TextButton(onPressed: onRetry, child: const Text('重试')),
        ],
      ]),
    );
  }
}
