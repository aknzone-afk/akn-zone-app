import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Helpline icon (owner 11-Oct-2026): a lady with a headset and microphone,
/// the "customer care" sign, in place of the plain chat bubble.
class HelplineIcon extends StatelessWidget {
  final double size;
  final Color color;
  const HelplineIcon({super.key, this.size = 30, this.color = Colors.white});

  @override
  Widget build(BuildContext context) =>
      CustomPaint(size: Size.square(size), painter: _LadyPainter(color));
}

class _LadyPainter extends CustomPainter {
  final Color color;
  _LadyPainter(this.color);

  @override
  void paint(Canvas canvas, Size s) {
    final w = s.width;
    final fill = Paint()..color = color;
    final line = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = w * 0.075
      ..strokeCap = StrokeCap.round;
    final c = Offset(w * 0.5, w * 0.40);
    final r = w * 0.20;

    // Long hair behind the face (down to the shoulders).
    final hair = Path()
      ..moveTo(c.dx - r * 1.25, c.dy + r * 1.55)
      ..quadraticBezierTo(c.dx - r * 1.45, c.dy - r * 1.25, c.dx, c.dy - r * 1.3)
      ..quadraticBezierTo(c.dx + r * 1.45, c.dy - r * 1.25, c.dx + r * 1.25, c.dy + r * 1.55)
      ..close();
    canvas.drawPath(hair, fill..color = color.withValues(alpha: 0.55));
    fill.color = color;

    // Face.
    canvas.drawCircle(c, r, fill);

    // Shoulders / body.
    final body = Path()
      ..moveTo(w * 0.14, w * 0.98)
      ..quadraticBezierTo(w * 0.16, w * 0.70, w * 0.5, w * 0.68)
      ..quadraticBezierTo(w * 0.84, w * 0.70, w * 0.86, w * 0.98)
      ..close();
    canvas.drawPath(body, fill);

    // Headset band over the head.
    final band = Rect.fromCircle(center: c, radius: r * 1.45);
    canvas.drawArc(band, math.pi * 1.05, math.pi * 0.9, false, line);
    // Ear cups.
    final cup = Paint()..color = color;
    canvas.drawRRect(
        RRect.fromRectAndRadius(
            Rect.fromCenter(center: Offset(c.dx - r * 1.45, c.dy + r * 0.15), width: w * 0.12, height: w * 0.2),
            Radius.circular(w * 0.04)),
        cup);
    canvas.drawRRect(
        RRect.fromRectAndRadius(
            Rect.fromCenter(center: Offset(c.dx + r * 1.45, c.dy + r * 0.15), width: w * 0.12, height: w * 0.2),
            Radius.circular(w * 0.04)),
        cup);
    // Microphone boom to the mouth.
    final boom = Path()
      ..moveTo(c.dx - r * 1.45, c.dy + r * 0.45)
      ..quadraticBezierTo(c.dx - r * 1.2, c.dy + r * 1.35, c.dx - r * 0.15, c.dy + r * 1.05);
    canvas.drawPath(boom, line..strokeWidth = w * 0.055);
    canvas.drawCircle(Offset(c.dx - r * 0.1, c.dy + r * 1.05), w * 0.05, cup);
  }

  @override
  bool shouldRepaint(covariant _LadyPainter old) => old.color != color;
}
