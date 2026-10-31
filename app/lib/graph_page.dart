import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'editor_page.dart';
import 'library.dart';
import 'scope.dart';
import 'session.dart';

class GraphPage extends StatelessWidget {
  const GraphPage({super.key});

  @override
  Widget build(BuildContext context) {
    final notes = Scope.of(context).notes.where((n) => !n.folder && !n.trashed).toList();
    final edges = wikiEdges(notes);
    return Scaffold(
      appBar: AppBar(title: const Text('图谱')),
      body: notes.isEmpty
          ? const Center(child: Text('还没有可以连起来的笔记。用 [[标题]] 把两篇连上。'))
          : LayoutBuilder(
              builder: (context, box) {
                final spots = _spots(notes, Size(box.maxWidth, box.maxHeight));
                return GestureDetector(
                  onTapUp: (d) {
                    Note? hit;
                    var best = 28.0;
                    for (final e in spots.entries) {
                      final dist = (e.value - d.localPosition).distance;
                      if (dist < best) {
                        best = dist;
                        hit = e.key;
                      }
                    }
                    if (hit != null) {
                      Navigator.of(context).push(MaterialPageRoute(builder: (_) => EditorPage(noteId: hit!.id)));
                    }
                  },
                  child: CustomPaint(
                    size: Size(box.maxWidth, box.maxHeight),
                    painter: _GraphPainter(spots: spots, edges: edges),
                  ),
                );
              },
            ),
    );
  }
}

Map<Note, Offset> _spots(List<Note> notes, Size size) {
  final out = <Note, Offset>{};
  final cx = size.width / 2;
  final cy = size.height / 2;
  final r = math.min(size.width, size.height) * 0.36;
  for (var i = 0; i < notes.length; i++) {
    final a = notes.length == 1 ? -math.pi / 2 : -math.pi / 2 + i * 2 * math.pi / notes.length;
    out[notes[i]] = Offset(cx + r * math.cos(a), cy + r * math.sin(a));
  }
  return out;
}

class _GraphPainter extends CustomPainter {
  _GraphPainter({required this.spots, required this.edges});
  final Map<Note, Offset> spots;
  final List<GraphEdge> edges;

  @override
  void paint(Canvas canvas, Size size) {
    final line = Paint()
      ..color = const Color(0xFF8A8F98)
      ..strokeWidth = 1.4;
    final byId = {for (final n in spots.keys) n.id: n};
    for (final e in edges) {
      final a = byId[e.fromId];
      final b = byId[e.toId];
      if (a == null || b == null) continue;
      canvas.drawLine(spots[a]!, spots[b]!, line);
    }
    for (final e in spots.entries) {
      final color = _color(e.key.color);
      canvas.drawCircle(e.value, 16, Paint()..color = color);
      final tp = TextPainter(
        text: TextSpan(text: e.key.heading, style: const TextStyle(fontSize: 12, color: Color(0xFF1C1C1C))),
        textDirection: TextDirection.ltr,
        maxLines: 1,
        ellipsis: '…',
      )..layout(maxWidth: 96);
      tp.paint(canvas, e.value + const Offset(18, -8));
    }
  }

  Color _color(String name) => switch (name) {
        'red' => const Color(0xFFE57373),
        'amber' => const Color(0xFFFFD54F),
        'green' => const Color(0xFF81C784),
        'blue' => const Color(0xFF64B5F6),
        'purple' => const Color(0xFFBA68C8),
        _ => const Color(0xFF90A4AE),
      };

  @override
  bool shouldRepaint(covariant _GraphPainter old) => true;
}
