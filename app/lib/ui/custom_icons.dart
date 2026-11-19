import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'ds.dart';

/// 自绘 Apple 风格双色调矢量图标系统（彻底替代系统 Emoji 字体）。
///
/// 所有路径均基于 24×24 逻辑坐标系通过 [CustomPainter] 直接绘制，
/// 在 Windows、Linux 与 Android 各 DPI 缩放下保持锐利一致，
/// 同时自动兼容历史同步数据中残留的旧 Emoji 字符串。
class SyncIcon extends StatelessWidget {
  final String name;
  final double size;
  final Color? color;

  const SyncIcon(this.name, {super.key, this.size = 20, this.color});

  static const folderChoices = <String>[
    'folder',
    'archive',
    'book',
    'briefcase',
    'home',
    'star',
    'lock',
    'clip',
    'bulb',
    'target',
    'pin',
    'leaf',
  ];

  static const pageChoices = <String>[
    'doc',
    'note',
    'pin',
    'clip',
    'book',
    'open_book',
    'archive',
    'folder',
    'bulb',
    'star',
    'flame',
    'check',
    'alert',
    'question',
    'warn',
    'target',
    'rocket',
    'brain',
    'briefcase',
    'home',
    'cart',
    'coin',
    'calendar',
    'clock',
    'sparkle',
    'heart',
    'leaf',
    'coffee',
    'music',
    'palette',
    'wrench',
    'laptop',
    'phone',
    'bug',
    'lock',
    'globe',
    'plane',
    'chat',
    'image',
    'moon',
  ];

  static const _legacyEmojiToKey = <String, String>{
    '📄': 'doc',
    '📝': 'note',
    '📌': 'pin',
    '📎': 'clip',
    '📚': 'book',
    '📖': 'open_book',
    '🗂': 'archive',
    '🗂️': 'archive',
    '📁': 'folder',
    '💡': 'bulb',
    '⭐': 'star',
    '🔥': 'flame',
    '✅': 'check',
    '❗': 'alert',
    '❓': 'question',
    '⚠': 'warn',
    '⚠️': 'warn',
    '🎯': 'target',
    '🚀': 'rocket',
    '🧠': 'brain',
    '💼': 'briefcase',
    '🏠': 'home',
    '🛒': 'cart',
    '💰': 'coin',
    '📅': 'calendar',
    '⏰': 'clock',
    '🎉': 'sparkle',
    '❤': 'heart',
    '❤️': 'heart',
    '🌱': 'leaf',
    '🍀': 'leaf',
    '☕': 'coffee',
    '🎵': 'music',
    '🎨': 'palette',
    '🔧': 'wrench',
    '💻': 'laptop',
    '📱': 'phone',
    '🐞': 'bug',
    '🔒': 'lock',
    '🌏': 'globe',
    '🌐': 'globe',
    '✈': 'plane',
    '✈️': 'plane',
    '💬': 'chat',
    '🖼️': 'image',
    '🖼': 'image',
    '🌙': 'moon',
    '☀️': 'sun',
    '☀': 'sun',
    '💧': 'drop',
  };

  static String normalizeKey(String? raw, {String fallback = 'doc'}) {
    if (raw == null || raw.trim().isEmpty) return fallback;
    final trimmed = raw.trim();
    if (_legacyEmojiToKey.containsKey(trimmed)) return _legacyEmojiToKey[trimmed]!;
    return trimmed;
  }

  static Color _accentFor(String key, AppColors c, bool dark) {
    return switch (key) {
      'folder' || 'archive' || 'doc' || 'note' || 'chat' || 'globe' || 'plane' || 'drop' => c.accent,
      'bulb' || 'star' || 'warn' || 'coin' || 'sun' || 'sparkle' => c.warning,
      'flame' || 'alert' || 'heart' || 'pin' || 'target' || 'bug' => c.danger,
      'check' || 'leaf' || 'shield' => c.success,
      'lock' || 'briefcase' || 'laptop' || 'phone' || 'wrench' || 'clock' || 'clip' =>
        dark ? const Color(0xFFAEAEB2) : const Color(0xFF5A5A60),
      'rocket' || 'brain' || 'music' || 'palette' || 'moon' || 'book' || 'open_book' =>
        dark ? const Color(0xFFBF5AF2) : const Color(0xFFAF52DE),
      'home' || 'cart' || 'calendar' || 'coffee' || 'image' || 'question' =>
        dark ? const Color(0xFF64D2FF) : const Color(0xFF007AFF),
      _ => c.accent,
    };
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final key = normalizeKey(name);
    final tint = color ?? _accentFor(key, c, dark);
    return SizedBox.square(
      dimension: size,
      child: CustomPaint(
        size: Size.square(size),
        painter: _SyncIconPainter(key: key, color: tint, dark: dark),
      ),
    );
  }
}

class _SyncIconPainter extends CustomPainter {
  final String key;
  final Color color;
  final bool dark;

  const _SyncIconPainter({required this.key, required this.color, required this.dark});

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 24.0;
    canvas.save();
    canvas.scale(s, s);

    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.9
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final fill = Paint()
      ..color = color.withValues(alpha: dark ? 0.22 : 0.16)
      ..style = PaintingStyle.fill;

    final solid = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    switch (key) {
      case 'folder':
        final p = Path()
          ..moveTo(3, 7)
          ..quadraticBezierTo(3, 5, 5, 5)
          ..lineTo(9.2, 5)
          ..lineTo(11.2, 7.5)
          ..lineTo(19, 7.5)
          ..quadraticBezierTo(21, 7.5, 21, 9.5)
          ..lineTo(21, 17.5)
          ..quadraticBezierTo(21, 19.5, 19, 19.5)
          ..lineTo(5, 19.5)
          ..quadraticBezierTo(3, 19.5, 3, 17.5)
          ..close();
        canvas.drawPath(p, fill);
        canvas.drawPath(p, stroke);
        break;

      case 'archive':
        final box = RRect.fromLTRBR(3.5, 8.5, 20.5, 19.5, const Radius.circular(2.5));
        final lid = RRect.fromLTRBR(2.5, 4.5, 21.5, 8.5, const Radius.circular(1.8));
        canvas.drawRRect(box, fill);
        canvas.drawRRect(box, stroke);
        canvas.drawRRect(lid, stroke);
        canvas.drawLine(const Offset(9.5, 13), const Offset(14.5, 13), stroke);
        break;

      case 'doc':
        final p = Path()
          ..moveTo(6, 3.5)
          ..lineTo(14.5, 3.5)
          ..lineTo(18.5, 7.5)
          ..lineTo(18.5, 19.5)
          ..quadraticBezierTo(18.5, 20.5, 17.5, 20.5)
          ..lineTo(6.5, 20.5)
          ..quadraticBezierTo(5.5, 20.5, 5.5, 19.5)
          ..lineTo(5.5, 4.5)
          ..quadraticBezierTo(5.5, 3.5, 6, 3.5)
          ..close();
        canvas.drawPath(p, fill);
        canvas.drawPath(p, stroke);
        canvas.drawPath(Path()..moveTo(14, 3.5)..lineTo(14, 8)..lineTo(18.5, 8), stroke);
        canvas.drawLine(const Offset(8.5, 12), const Offset(15.5, 12), stroke);
        canvas.drawLine(const Offset(8.5, 15.5), const Offset(13.5, 15.5), stroke);
        break;

      case 'note':
        final r = RRect.fromLTRBR(4, 4, 20, 20, const Radius.circular(3.5));
        canvas.drawRRect(r, fill);
        canvas.drawRRect(r, stroke);
        canvas.drawLine(const Offset(7.5, 9), const Offset(16.5, 9), stroke);
        canvas.drawLine(const Offset(7.5, 12.8), const Offset(16.5, 12.8), stroke);
        canvas.drawLine(const Offset(7.5, 16.5), const Offset(12.5, 16.5), stroke);
        break;

      case 'chat':
        final p = Path()
          ..moveTo(4.5, 6.5)
          ..quadraticBezierTo(4.5, 4.5, 6.5, 4.5)
          ..lineTo(17.5, 4.5)
          ..quadraticBezierTo(19.5, 4.5, 19.5, 6.5)
          ..lineTo(19.5, 14.5)
          ..quadraticBezierTo(19.5, 16.5, 17.5, 16.5)
          ..lineTo(10, 16.5)
          ..lineTo(6, 20)
          ..lineTo(6.5, 16.5)
          ..quadraticBezierTo(4.5, 16.5, 4.5, 14.5)
          ..close();
        canvas.drawPath(p, fill);
        canvas.drawPath(p, stroke);
        canvas.drawLine(const Offset(8, 9.2), const Offset(16, 9.2), stroke);
        canvas.drawLine(const Offset(8, 12.5), const Offset(13.5, 12.5), stroke);
        break;

      case 'clip':
        final p = Path()
          ..moveTo(15.5, 7.5)
          ..lineTo(9.2, 13.8)
          ..arcToPoint(const Offset(12, 16.6), radius: const Radius.circular(2.0), clockwise: false)
          ..lineTo(18.5, 10.1)
          ..arcToPoint(const Offset(12.8, 4.4), radius: const Radius.circular(4.0), clockwise: false)
          ..lineTo(6.2, 11.0)
          ..arcToPoint(const Offset(14.6, 19.4), radius: const Radius.circular(5.9), clockwise: false)
          ..lineTo(19, 15);
        canvas.drawPath(p, stroke);
        break;

      case 'bulb':
        canvas.drawCircle(const Offset(12, 9.5), 5.2, fill);
        canvas.drawArc(const Rect.fromLTWH(6.8, 4.3, 10.4, 10.4), math.pi * 0.72, math.pi * 1.56, false, stroke);
        canvas.drawLine(const Offset(9.5, 14.2), const Offset(9.5, 16.8), stroke);
        canvas.drawLine(const Offset(14.5, 14.2), const Offset(14.5, 16.8), stroke);
        canvas.drawLine(const Offset(9.5, 16.8), const Offset(14.5, 16.8), stroke);
        canvas.drawLine(const Offset(10.3, 19.6), const Offset(13.7, 19.6), stroke);
        break;

      case 'star':
        final p = _starPath(12, 12, 8.2, 3.8, 5);
        canvas.drawPath(p, fill);
        canvas.drawPath(p, stroke);
        break;

      case 'lock':
        final body = RRect.fromLTRBR(5.5, 10.5, 18.5, 19.5, const Radius.circular(2.5));
        canvas.drawRRect(body, fill);
        canvas.drawRRect(body, stroke);
        final shackle = Path()
          ..moveTo(8.5, 10.5)
          ..lineTo(8.5, 7.8)
          ..arcToPoint(const Offset(15.5, 7.8), radius: const Radius.circular(3.5))
          ..lineTo(15.5, 10.5);
        canvas.drawPath(shackle, stroke);
        canvas.drawCircle(const Offset(12, 15), 1.3, solid);
        break;

      case 'book':
      case 'open_book':
        final left = RRect.fromLTRBR(4, 4.5, 12, 19.5, const Radius.circular(1.8));
        final right = RRect.fromLTRBR(12, 4.5, 20, 19.5, const Radius.circular(1.8));
        canvas.drawRRect(left, fill);
        canvas.drawRRect(right, fill);
        canvas.drawRRect(left, stroke);
        canvas.drawRRect(right, stroke);
        break;

      case 'briefcase':
        final body = RRect.fromLTRBR(3.5, 8, 20.5, 19, const Radius.circular(2.5));
        canvas.drawRRect(body, fill);
        canvas.drawRRect(body, stroke);
        canvas.drawRRect(RRect.fromLTRBR(8.5, 4.8, 15.5, 8, const Radius.circular(1.5)), stroke);
        canvas.drawLine(const Offset(3.5, 12.5), const Offset(20.5, 12.5), stroke);
        break;

      case 'home':
        final p = Path()
          ..moveTo(3.5, 11.2)
          ..lineTo(12, 4)
          ..lineTo(20.5, 11.2)
          ..moveTo(6, 9.5)
          ..lineTo(6, 19.5)
          ..lineTo(18, 19.5)
          ..lineTo(18, 9.5);
        final inner = Path()
          ..moveTo(6, 9.5)
          ..lineTo(12, 4.5)
          ..lineTo(18, 9.5)
          ..lineTo(18, 19.5)
          ..lineTo(6, 19.5)
          ..close();
        canvas.drawPath(inner, fill);
        canvas.drawPath(p, stroke);
        break;

      case 'target':
        canvas.drawCircle(const Offset(12, 12), 8, fill);
        canvas.drawCircle(const Offset(12, 12), 8, stroke);
        canvas.drawCircle(const Offset(12, 12), 4.5, stroke);
        canvas.drawCircle(const Offset(12, 12), 1.6, solid);
        break;

      case 'pin':
        final p = Path()
          ..moveTo(9, 4.5)
          ..lineTo(15, 4.5)
          ..lineTo(14.2, 10.5)
          ..lineTo(17, 13.5)
          ..lineTo(7, 13.5)
          ..lineTo(9.8, 10.5)
          ..close();
        canvas.drawPath(p, fill);
        canvas.drawPath(p, stroke);
        canvas.drawLine(const Offset(12, 13.5), const Offset(12, 20), stroke);
        break;

      case 'leaf':
        final p = Path()
          ..moveTo(6, 18.5)
          ..quadraticBezierTo(5.5, 8.5, 18.5, 5.5)
          ..quadraticBezierTo(18.5, 17.5, 6, 18.5)
          ..close();
        canvas.drawPath(p, fill);
        canvas.drawPath(p, stroke);
        canvas.drawLine(const Offset(6, 18.5), const Offset(14.5, 10), stroke);
        break;

      case 'flame':
        final p = Path()
          ..moveTo(12, 3.8)
          ..quadraticBezierTo(18.5, 9.2, 17.8, 14.5)
          ..quadraticBezierTo(17.2, 19.8, 12, 20.2)
          ..quadraticBezierTo(6.8, 19.8, 6.2, 14.5)
          ..quadraticBezierTo(5.8, 10.5, 9.5, 7.6)
          ..quadraticBezierTo(9.8, 10.2, 12, 10.2)
          ..quadraticBezierTo(12.2, 7, 12, 3.8)
          ..close();
        canvas.drawPath(p, fill);
        canvas.drawPath(p, stroke);
        break;

      case 'check':
        canvas.drawCircle(const Offset(12, 12), 8.2, fill);
        canvas.drawCircle(const Offset(12, 12), 8.2, stroke);
        canvas.drawPath(Path()..moveTo(8.3, 12.2)..lineTo(10.8, 14.8)..lineTo(15.8, 9.4), stroke);
        break;

      case 'alert':
        canvas.drawCircle(const Offset(12, 12), 8.2, fill);
        canvas.drawCircle(const Offset(12, 12), 8.2, stroke);
        canvas.drawLine(const Offset(12, 8), const Offset(12, 13), stroke);
        canvas.drawCircle(const Offset(12, 16), 1.0, solid);
        break;

      case 'question':
        canvas.drawCircle(const Offset(12, 12), 8.2, fill);
        canvas.drawCircle(const Offset(12, 12), 8.2, stroke);
        final q = Path()
          ..moveTo(9.8, 9.5)
          ..quadraticBezierTo(10, 7.5, 12.2, 7.5)
          ..quadraticBezierTo(14.5, 7.5, 14.5, 9.5)
          ..quadraticBezierTo(14.5, 11, 12, 12)
          ..lineTo(12, 13.5);
        canvas.drawPath(q, stroke);
        canvas.drawCircle(const Offset(12, 16.3), 1.0, solid);
        break;

      case 'warn':
        final p = Path()
          ..moveTo(12, 4.2)
          ..lineTo(20, 18.8)
          ..lineTo(4, 18.8)
          ..close();
        canvas.drawPath(p, fill);
        canvas.drawPath(p, stroke);
        canvas.drawLine(const Offset(12, 9.5), const Offset(12, 13.8), stroke);
        canvas.drawCircle(const Offset(12, 16.4), 1.0, solid);
        break;

      case 'heart':
        final p = Path()
          ..moveTo(12, 19.2)
          ..cubicTo(5, 14.5, 4, 8.8, 7.2, 6.2)
          ..cubicTo(9.4, 4.5, 11.4, 5.8, 12, 7.4)
          ..cubicTo(12.6, 5.8, 14.6, 4.5, 16.8, 6.2)
          ..cubicTo(20, 8.8, 19, 14.5, 12, 19.2)
          ..close();
        canvas.drawPath(p, fill);
        canvas.drawPath(p, stroke);
        break;

      case 'clock':
        canvas.drawCircle(const Offset(12, 12), 8.2, fill);
        canvas.drawCircle(const Offset(12, 12), 8.2, stroke);
        canvas.drawPath(Path()..moveTo(12, 7.5)..lineTo(12, 12.2)..lineTo(15.5, 14), stroke);
        break;

      case 'calendar':
        final r = RRect.fromLTRBR(4, 5.5, 20, 19.5, const Radius.circular(2.5));
        canvas.drawRRect(r, fill);
        canvas.drawRRect(r, stroke);
        canvas.drawLine(const Offset(4, 10), const Offset(20, 10), stroke);
        canvas.drawLine(const Offset(8.5, 3.8), const Offset(8.5, 7), stroke);
        canvas.drawLine(const Offset(15.5, 3.8), const Offset(15.5, 7), stroke);
        break;

      case 'image':
        final r = RRect.fromLTRBR(3.8, 5, 20.2, 19, const Radius.circular(2.5));
        canvas.drawRRect(r, fill);
        canvas.drawRRect(r, stroke);
        canvas.drawCircle(const Offset(8.5, 9.2), 1.4, solid);
        canvas.drawPath(Path()..moveTo(5.5, 17.5)..lineTo(10.5, 12.5)..lineTo(13.8, 15.6)..lineTo(16.2, 13.2)..lineTo(19, 17.5), stroke);
        break;

      case 'globe':
        canvas.drawCircle(const Offset(12, 12), 8.2, fill);
        canvas.drawCircle(const Offset(12, 12), 8.2, stroke);
        canvas.drawOval(const Rect.fromLTWH(8.2, 3.8, 7.6, 16.4), stroke);
        canvas.drawLine(const Offset(4, 12), const Offset(20, 12), stroke);
        break;

      case 'laptop':
        final screen = RRect.fromLTRBR(5, 5.5, 19, 15.5, const Radius.circular(1.8));
        canvas.drawRRect(screen, fill);
        canvas.drawRRect(screen, stroke);
        canvas.drawLine(const Offset(3, 18.5), const Offset(21, 18.5), stroke);
        break;

      case 'phone':
        final body = RRect.fromLTRBR(7, 3.8, 17, 20.2, const Radius.circular(2.4));
        canvas.drawRRect(body, fill);
        canvas.drawRRect(body, stroke);
        canvas.drawLine(const Offset(10.5, 17.5), const Offset(13.5, 17.5), stroke);
        break;

      case 'moon':
        final p = Path()
          ..moveTo(15.2, 4.6)
          ..arcToPoint(const Offset(19.4, 15.8), radius: const Radius.circular(8.2), largeArc: true, clockwise: false)
          ..arcToPoint(const Offset(15.2, 4.6), radius: const Radius.circular(6.6), clockwise: true)
          ..close();
        canvas.drawPath(p, fill);
        canvas.drawPath(p, stroke);
        break;

      case 'sun':
        canvas.drawCircle(const Offset(12, 12), 4.2, fill);
        canvas.drawCircle(const Offset(12, 12), 4.2, stroke);
        for (var i = 0; i < 8; i++) {
          final a = i * math.pi / 4;
          canvas.drawLine(
            Offset(12 + math.cos(a) * 6.5, 12 + math.sin(a) * 6.5),
            Offset(12 + math.cos(a) * 8.8, 12 + math.sin(a) * 8.8),
            stroke,
          );
        }
        break;

      case 'drop':
        final p = Path()
          ..moveTo(12, 3.8)
          ..cubicTo(16.8, 9.8, 18, 12.6, 18, 14.8)
          ..arcToPoint(const Offset(6, 14.8), radius: const Radius.circular(6), clockwise: true)
          ..cubicTo(6, 12.6, 7.2, 9.8, 12, 3.8)
          ..close();
        canvas.drawPath(p, fill);
        canvas.drawPath(p, stroke);
        break;

      case 'rocket':
      case 'plane':
        final p = Path()
          ..moveTo(19.5, 4.5)
          ..lineTo(13.2, 19.5)
          ..lineTo(10.8, 13.2)
          ..lineTo(4.5, 10.8)
          ..close();
        canvas.drawPath(p, fill);
        canvas.drawPath(p, stroke);
        break;

      case 'sparkle':
        final p = _starPath(12, 12, 8.2, 2.8, 4);
        canvas.drawPath(p, fill);
        canvas.drawPath(p, stroke);
        break;

      default:
        // 统一圆角菱形徽标兜底（如 brain/cart/coin/coffee/music/palette/wrench/bug 等）
        final r = RRect.fromLTRBR(4.5, 4.5, 19.5, 19.5, const Radius.circular(4.5));
        canvas.drawRRect(r, fill);
        canvas.drawRRect(r, stroke);
        canvas.drawCircle(const Offset(12, 12), 2.8, solid);
        break;
    }

    canvas.restore();
  }

  static Path _starPath(double cx, double cy, double outer, double inner, int points) {
    final p = Path();
    for (var i = 0; i < points * 2; i++) {
      final r = i.isEven ? outer : inner;
      final a = -math.pi / 2 + i * math.pi / points;
      final x = cx + math.cos(a) * r;
      final y = cy + math.sin(a) * r;
      if (i == 0) {
        p.moveTo(x, y);
      } else {
        p.lineTo(x, y);
      }
    }
    p.close();
    return p;
  }

  @override
  bool shouldRepaint(covariant _SyncIconPainter old) =>
      old.key != key || old.color != color || old.dark != dark;
}
