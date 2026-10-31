import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

class DrawPage extends StatefulWidget {
  const DrawPage({super.key});

  @override
  State<DrawPage> createState() => DrawPageState();
}

class DrawPageState extends State<DrawPage> {
  final _strokes = <List<Offset>>[];
  final _key = GlobalKey();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('手写'),
        actions: [
          TextButton(onPressed: () => setState(_strokes.clear), child: const Text('清空')),
          TextButton(onPressed: _save, child: const Text('放进笔记')),
        ],
      ),
      body: RepaintBoundary(
        key: _key,
        child: GestureDetector(
          onPanStart: (d) => setState(() => _strokes.add([d.localPosition])),
          onPanUpdate: (d) => setState(() => _strokes.last.add(d.localPosition)),
          child: CustomPaint(
            painter: _InkPainter(_strokes),
            child: const SizedBox.expand(),
          ),
        ),
      ),
    );
  }

  Future<void> _save() async {
    final boundary = _key.currentContext?.findRenderObject() as RenderRepaintBoundary?;
    if (boundary == null) return;
    final image = await boundary.toImage(pixelRatio: 2);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    if (!mounted || bytes == null) return;
    Navigator.pop(context, bytes.buffer.asUint8List());
  }
}

class _InkPainter extends CustomPainter {
  _InkPainter(this.strokes);
  final List<List<Offset>> strokes;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFFFFFBF2));
    final pen = Paint()
      ..color = const Color(0xFF1A1A1A)
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    for (final stroke in strokes) {
      if (stroke.length < 2) continue;
      final path = Path()..moveTo(stroke.first.dx, stroke.first.dy);
      for (final p in stroke.skip(1)) {
        path.lineTo(p.dx, p.dy);
      }
      canvas.drawPath(path, pen);
    }
  }

  @override
  bool shouldRepaint(covariant _InkPainter old) => true;
}
