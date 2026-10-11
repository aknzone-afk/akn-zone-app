import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// A single stroke in the markup canvas.
@immutable
class MarkupStroke {
  final List<Offset> points; // in *canvas* coordinates
  final Color color;
  final double width;

  const MarkupStroke(
      {required this.points, required this.color, required this.width});

  Map<String, dynamic> toJson() => {
        'c': color.toARGB32(),
        'w': width,
        'p': [
          for (final o in points) ...[o.dx, o.dy]
        ],
      };

  factory MarkupStroke.fromJson(Map<String, dynamic> j) {
    final flat = (j['p'] as List).cast<num>();
    return MarkupStroke(
      points: [
        for (int i = 0; i + 1 < flat.length; i += 2)
          Offset(flat[i].toDouble(), flat[i + 1].toDouble()),
      ],
      color: Color((j['c'] as num).toInt()),
      width: (j['w'] as num).toDouble(),
    );
  }
}

/// Serialise a stroke list to a JSON string for persistence.
String encodeMarkupStrokes(List<MarkupStroke> strokes) =>
    jsonEncode([for (final s in strokes) s.toJson()]);

/// Parse strokes previously saved with [encodeMarkupStrokes].
List<MarkupStroke> decodeMarkupStrokes(String source) {
  final raw = jsonDecode(source);
  if (raw is! List) return const [];
  return [
    for (final e in raw)
      if (e is Map) MarkupStroke.fromJson(Map<String, dynamic>.from(e)),
  ];
}

/// Renders a list of [MarkupStroke]s on top of an original image and returns
/// PNG bytes ready to share.
class MarkupCompositor {
  /// [originalBytes] is the original full-res image; [canvasSize] is the size
  /// (in logical pixels) of the widget the user drew on. Stroke points are
  /// scaled from canvas to image space.
  static Future<Uint8List> composite({
    required Uint8List originalBytes,
    required List<MarkupStroke> strokes,
    required Size canvasSize,
    int maxOutputWidth = 2048,
  }) async {
    final codec = await ui.instantiateImageCodec(originalBytes);
    final frame = await codec.getNextFrame();
    final image = frame.image;

    // Down-scale very large images to keep WhatsApp share fast.
    double targetW = image.width.toDouble();
    double targetH = image.height.toDouble();
    if (targetW > maxOutputWidth) {
      final scale = maxOutputWidth / targetW;
      targetW *= scale;
      targetH *= scale;
    }

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(
      recorder,
      Rect.fromLTWH(0, 0, targetW, targetH),
    );

    // 1. Draw original image scaled to target.
    final paintImage = Paint()..filterQuality = FilterQuality.medium;
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      Rect.fromLTWH(0, 0, targetW, targetH),
      paintImage,
    );

    // 2. Draw strokes, scaling canvas points → image points.
    final scaleX = targetW / canvasSize.width;
    final scaleY = targetH / canvasSize.height;

    for (final s in strokes) {
      if (s.points.isEmpty) continue;
      final paint = Paint()
        ..color = s.color
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke
        ..strokeWidth = s.width * ((scaleX + scaleY) / 2)
        ..isAntiAlias = true;

      if (s.points.length == 1) {
        // Single tap: render as filled dot.
        final p = s.points.first;
        canvas.drawCircle(
          Offset(p.dx * scaleX, p.dy * scaleY),
          paint.strokeWidth / 2,
          Paint()
            ..color = s.color
            ..isAntiAlias = true,
        );
        continue;
      }
      // Smooth quadratic curve through midpoints (matches the live canvas).
      Offset sp(Offset o) => Offset(o.dx * scaleX, o.dy * scaleY);
      final first = sp(s.points.first);
      final path = Path()..moveTo(first.dx, first.dy);
      for (int i = 1; i < s.points.length - 1; i++) {
        final c = sp(s.points[i]);
        final next = sp(s.points[i + 1]);
        path.quadraticBezierTo(
            c.dx, c.dy, (c.dx + next.dx) / 2, (c.dy + next.dy) / 2);
      }
      final last = sp(s.points.last);
      path.lineTo(last.dx, last.dy);
      canvas.drawPath(path, paint);
    }

    final picture = recorder.endRecording();
    final composedImg = await picture.toImage(targetW.round(), targetH.round());
    final byteData =
        await composedImg.toByteData(format: ui.ImageByteFormat.png);
    if (byteData == null) {
      throw Exception('Failed to encode composed image');
    }
    composedImg.dispose();
    image.dispose();
    return byteData.buffer.asUint8List();
  }
}
