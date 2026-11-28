import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../models/block.dart';
import '../tasks/task_models.dart';
import 'ds.dart';

Color taskPriorityColor(AppColors c, TaskPriority p) => switch (p) {
      TaskPriority.urgent => c.danger,
      TaskPriority.high => c.warning,
      TaskPriority.medium => c.accent,
      TaskPriority.low => c.text2,
      TaskPriority.none => c.text3,
    };

Color taskHealthColor(AppColors c, TaskHealth h) => switch (h) {
      TaskHealth.completed => c.success,
      TaskHealth.cancelled => c.text3,
      TaskHealth.overdue => c.danger,
      TaskHealth.atRisk => c.warning,
      TaskHealth.onTrack => c.success,
      TaskHealth.notStarted => c.text3,
      TaskHealth.inProgress => c.accent,
    };

/// Things 式进度环：字母大小，描边表示完成比例。
class TaskProgressRing extends StatelessWidget {
  final double progress;
  final Color color;
  final double size;
  final double stroke;
  const TaskProgressRing({
    super.key,
    required this.progress,
    required this.color,
    this.size = 22,
    this.stroke = 2.4,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return SizedBox.square(
      dimension: size,
      child: CustomPaint(
        painter: _RingPainter(
          progress: progress.clamp(0, 1),
          color: color,
          track: c.separator,
          stroke: stroke,
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  final double progress;
  final Color color;
  final Color track;
  final double stroke;
  _RingPainter({required this.progress, required this.color, required this.track, required this.stroke});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final r = (math.min(size.width, size.height) - stroke) / 2;
    final trackPaint = Paint()
      ..color = track
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;
    final fillPaint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;
    canvas.drawCircle(center, r, trackPaint);
    if (progress >= 0.999) {
      canvas.drawCircle(center, r, fillPaint);
      return;
    }
    if (progress <= 0) return;
    canvas.drawArc(Rect.fromCircle(center: center, radius: r), -math.pi / 2, 2 * math.pi * progress, false, fillPaint);
  }

  @override
  bool shouldRepaint(covariant _RingPainter old) =>
      old.progress != progress || old.color != color || old.track != track || old.stroke != stroke;
}

class TaskPriorityFlag extends StatelessWidget {
  final TaskPriority priority;
  const TaskPriorityFlag({super.key, required this.priority});

  @override
  Widget build(BuildContext context) {
    if (priority == TaskPriority.none) return const SizedBox.shrink();
    final c = AppColors.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(CupertinoIcons.flag_fill, size: 11, color: taskPriorityColor(c, priority)),
        const SizedBox(width: 3),
        Text(
          taskPriorityLabel(priority),
          maxLines: 1,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                fontSize: 11,
                height: 1.1,
                color: taskPriorityColor(c, priority),
                fontWeight: FontWeight.w500,
              ),
        ),
      ],
    );
  }
}

String taskDateCaption(Block b, {DateTime? now}) {
  final d = taskDataOf(b);
  final t = now ?? DateTime.now();
  if (d.status == TaskStatus.done && d.completedAt != null) {
    return '完成于 ${formatTaskDate(d.completedAt, allDay: d.allDay)}';
  }
  if (isOverdueAt(d, t) && d.dueAt != null) {
    return '逾期 · ${formatTaskDate(d.dueAt, allDay: d.allDay)}';
  }
  final parts = <String>[];
  if (d.startAt != null) parts.add('开始 ${formatTaskDate(d.startAt, allDay: d.allDay)}');
  if (d.dueAt != null) parts.add('截止 ${formatTaskDate(d.dueAt, allDay: d.allDay)}');
  return parts.join(' · ');
}
