import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../services/transfer_queue.dart';
import 'ds.dart';

String formatBytes(num n) {
  final v = n.toDouble();
  if (v < 1024) return '${v.round()} B';
  if (v < 1024 * 1024) return '${(v / 1024).toStringAsFixed(1)} KB';
  if (v < 1024 * 1024 * 1024) return '${(v / 1024 / 1024).toStringAsFixed(1)} MB';
  return '${(v / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
}

String formatSpeed(double bps) => bps < 1 ? '—' : '${formatBytes(bps)}/s';

String? formatEta(TransferJob j) {
  if (j.status != TransferStatus.running || j.speed < 1 || j.total <= j.done) return null;
  final s = ((j.total - j.done) / j.speed).round();
  if (s < 60) return '剩余 $s 秒';
  if (s < 3600) return '剩余 ${s ~/ 60} 分 ${s % 60} 秒';
  return '剩余 ${s ~/ 3600} 时 ${(s % 3600) ~/ 60} 分';
}

String formatPct(TransferJob j) {
  if (j.confirming) return '确认中';
  if (j.status == TransferStatus.failed) return '失败';
  if (j.total <= 0) return formatBytes(j.done);
  final p = (100 * j.done / j.total).clamp(0, 99);
  if (j.status == TransferStatus.done) return '100%';
  return '${p.toStringAsFixed(0)}%';
}

class TransferPage extends StatelessWidget {
  const TransferPage({super.key});

  @override
  Widget build(BuildContext context) {
    final q = AppScope.of(context).transfers;
    return Scaffold(
      appBar: AppBar(
        title: const Text('传输'),
        actions: [
          ListenableBuilder(
            listenable: Listenable.merge([q, q.progress]),
            builder: (context, _) => TextButton(
              onPressed: q.jobs.any((j) =>
                      j.status == TransferStatus.done ||
                      j.status == TransferStatus.failed ||
                      j.status == TransferStatus.canceled)
                  ? q.clearFinished
                  : null,
              child: const Text('清除已完成'),
            ),
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: Listenable.merge([q, q.progress]),
        builder: (context, _) {
          if (q.jobs.isEmpty) {
            return Center(
              child: Text('没有传输任务', style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: AppColors.of(context).text3)),
            );
          }
          return ListView.builder(
            padding: const EdgeInsets.only(bottom: Gap.x3),
            itemCount: q.jobs.length,
            itemBuilder: (context, i) => _Tile(job: q.jobs[q.jobs.length - 1 - i], queue: q),
          );
        },
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  final TransferJob job;
  final TransferQueue queue;
  const _Tile({required this.job, required this.queue});

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final tt = Theme.of(context).textTheme;
    final up = job.dir == TransferDir.up;
    final eta = formatEta(job);
    final sub = switch (job.status) {
      TransferStatus.queued => '等待中',
      TransferStatus.running => job.confirming
          ? '正在等服务器确认'
          : [formatPct(job), formatSpeed(job.speed), ?eta].join(' · '),
      TransferStatus.done => '完成 · ${formatBytes(job.done == 0 ? job.total : job.done)}',
      TransferStatus.failed => job.error ?? '失败',
      TransferStatus.canceled => '已取消',
    };
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Gap.xl, vertical: Gap.m),
      child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
        Icon(up ? CupertinoIcons.arrow_up_circle : CupertinoIcons.arrow_down_circle, size: Sizes.iconMd, color: c.text2),
        const SizedBox(width: Gap.l),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(job.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: tt.bodyMedium),
            const SizedBox(height: 2),
            Text(sub, maxLines: job.status == TransferStatus.failed ? 3 : 1, overflow: TextOverflow.ellipsis, style: tt.bodySmall?.copyWith(color: job.status == TransferStatus.failed ? c.danger : c.text2)),
            if (job.status == TransferStatus.running || job.status == TransferStatus.queued) ...[
              const SizedBox(height: Gap.s),
              ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: LinearProgressIndicator(
                  minHeight: 3,
                  value: job.confirming || job.total <= 0 || job.status == TransferStatus.queued ? null : job.fraction,
                  backgroundColor: c.fill,
                  color: c.accent,
                ),
              ),
            ],
          ]),
        ),
        if (job.status == TransferStatus.running || job.status == TransferStatus.queued)
          IconButton(
            tooltip: '取消',
            onPressed: () => queue.cancel(job.id),
            icon: Icon(CupertinoIcons.xmark, size: Sizes.iconSm, color: c.text2),
          )
        else if (job.status == TransferStatus.failed || job.status == TransferStatus.canceled)
          IconButton(
            tooltip: '重试',
            onPressed: () => queue.retry(job.id),
            icon: Icon(CupertinoIcons.arrow_clockwise, size: Sizes.iconSm, color: c.text2),
          ),
      ]),
    );
  }
}

/// 底部一条，只在有任务时出现。点一下打开队列，不自动跳转。
class TransferStrip extends StatelessWidget {
  final VoidCallback onOpen;
  const TransferStrip({super.key, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    final q = AppScope.of(context).transfers;
    return ListenableBuilder(
      listenable: Listenable.merge([q, q.progress]),
      builder: (context, _) {
        final j = q.current;
        if (j == null) return const SizedBox.shrink();
        final c = AppColors.of(context);
        if (j.status == TransferStatus.failed) {
          return Material(
            color: c.sidebar,
            child: InkWell(
              onTap: onOpen,
              child: Container(
                key: const Key('transferStrip'),
                constraints: const BoxConstraints(minHeight: Sizes.bar),
                padding: const EdgeInsets.symmetric(horizontal: Gap.l, vertical: Gap.s),
                decoration: BoxDecoration(border: Border(top: BorderSide(color: c.separator))),
                child: Row(children: [
                  Icon(CupertinoIcons.exclamationmark_circle, size: Sizes.iconSm, color: c.danger),
                  const SizedBox(width: Gap.m),
                  Expanded(
                    child: Text(
                      '${j.name}：${j.error ?? '失败'}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(color: c.danger),
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭',
                    onPressed: () => q.dismiss(j.id),
                    icon: Icon(CupertinoIcons.xmark, size: Sizes.iconSm, color: c.text2),
                  ),
                ]),
              ),
            ),
          );
        }
        final extra = q.activeCount > 1 ? '  +${q.activeCount - 1}' : '';
        return Material(
          color: c.sidebar,
          child: InkWell(
            onTap: onOpen,
            child: Container(
              key: const Key('transferStrip'),
              height: Sizes.bar,
              padding: const EdgeInsets.symmetric(horizontal: Gap.l),
              decoration: BoxDecoration(border: Border(top: BorderSide(color: c.separator))),
              child: Row(children: [
                Icon(
                  j.dir == TransferDir.up ? CupertinoIcons.arrow_up : CupertinoIcons.arrow_down,
                  size: Sizes.iconSm,
                  color: c.accent,
                ),
                const SizedBox(width: Gap.m),
                Expanded(
                  child: Text(
                    '${j.name}$extra',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ),
                const SizedBox(width: Gap.m),
                Text(formatPct(j), style: Theme.of(context).textTheme.bodySmall?.copyWith(color: c.text2)),
                const SizedBox(width: Gap.m),
                Text(formatSpeed(j.speed), style: Theme.of(context).textTheme.bodySmall?.copyWith(color: c.text2)),
                const SizedBox(width: Gap.s),
                SizedBox(
                  width: 72,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: LinearProgressIndicator(
                      minHeight: 3,
                      value: j.confirming || j.total <= 0 ? null : j.fraction,
                      backgroundColor: c.fill,
                      color: c.accent,
                    ),
                  ),
                ),
              ]),
            ),
          ),
        );
      },
    );
  }
}
