import 'package:flutter/material.dart';

import '../services/markup_compositor.dart';

/// Draws strokes over a static child (the photo). Exposes a controller so
/// parent screens can read out strokes when sharing.
class MarkupCanvas extends StatefulWidget {
  final Widget child;
  final MarkupCanvasController controller;

  const MarkupCanvas({
    super.key,
    required this.child,
    required this.controller,
  });

  @override
  State<MarkupCanvas> createState() => _MarkupCanvasState();
}

class _MarkupCanvasState extends State<MarkupCanvas> {
  Offset? _current;
  List<Offset> _activePoints = [];
  Size _canvasSize = Size.zero;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onCtrl);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onCtrl);
    super.dispose();
  }

  void _onCtrl() => setState(() {});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      _canvasSize = Size(constraints.maxWidth, constraints.maxHeight);
      widget.controller._canvasSize = _canvasSize;
      return Stack(
        children: [
          Positioned.fill(child: widget.child),
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanStart: (d) {
                _activePoints = [d.localPosition];
                _current = d.localPosition;
                setState(() {});
              },
              onPanUpdate: (d) {
                _activePoints.add(d.localPosition);
                _current = d.localPosition;
                setState(() {});
              },
              onPanEnd: (_) {
                if (_activePoints.isNotEmpty) {
                  widget.controller._commitStroke(
                    MarkupStroke(
                      points: List.of(_activePoints),
                      color: widget.controller.color,
                      width: widget.controller.strokeWidth,
                    ),
                  );
                }
                _activePoints = [];
                _current = null;
                setState(() {});
              },
              child: CustomPaint(
                painter: _StrokePainter(
                  strokes: widget.controller.strokes,
                  activeStroke: _activePoints.isEmpty
                      ? null
                      : MarkupStroke(
                          points: _activePoints,
                          color: widget.controller.color,
                          width: widget.controller.strokeWidth,
                        ),
                ),
              ),
            ),
          ),
        ],
      );
    });
  }
}

class _StrokePainter extends CustomPainter {
  final List<MarkupStroke> strokes;
  final MarkupStroke? activeStroke;

  _StrokePainter({required this.strokes, this.activeStroke});

  void _paintStroke(Canvas canvas, MarkupStroke s) {
    if (s.points.isEmpty) return;
    final paint = Paint()
      ..color = s.color
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke
      ..strokeWidth = s.width
      ..isAntiAlias = true;
    if (s.points.length == 1) {
      canvas.drawCircle(
          s.points.first,
          s.width / 2,
          Paint()
            ..color = s.color
            ..isAntiAlias = true);
      return;
    }
    // Smooth the line with quadratic curves through the midpoints (WhatsApp-
    // style brush) instead of jagged straight segments.
    final path = Path()..moveTo(s.points.first.dx, s.points.first.dy);
    for (int i = 1; i < s.points.length - 1; i++) {
      final c = s.points[i];
      final next = s.points[i + 1];
      path.quadraticBezierTo(
          c.dx, c.dy, (c.dx + next.dx) / 2, (c.dy + next.dy) / 2);
    }
    path.lineTo(s.points.last.dx, s.points.last.dy);
    canvas.drawPath(path, paint);
  }

  @override
  void paint(Canvas canvas, Size size) {
    for (final s in strokes) {
      _paintStroke(canvas, s);
    }
    if (activeStroke != null) _paintStroke(canvas, activeStroke!);
  }

  @override
  bool shouldRepaint(covariant _StrokePainter old) =>
      old.strokes != strokes || old.activeStroke != activeStroke;
}

class MarkupCanvasController extends ChangeNotifier {
  final List<MarkupStroke> _strokes = [];
  Color color;
  double strokeWidth;
  Size _canvasSize = Size.zero;

  MarkupCanvasController({
    this.color = const Color(0xFFE53935),
    this.strokeWidth = 6.0,
  });

  List<MarkupStroke> get strokes => List.unmodifiable(_strokes);
  Size get canvasSize => _canvasSize;
  bool get hasStrokes => _strokes.isNotEmpty;

  void setColor(Color c) {
    color = c;
    notifyListeners();
  }

  void setStrokeWidth(double w) {
    strokeWidth = w;
    notifyListeners();
  }

  void _commitStroke(MarkupStroke s) {
    _strokes.add(s);
    notifyListeners();
  }

  void undo() {
    if (_strokes.isNotEmpty) {
      _strokes.removeLast();
      notifyListeners();
    }
  }

  /// Replace the current strokes with a restored set (re-opening a saved edit).
  void restoreStrokes(List<MarkupStroke> strokes) {
    _strokes
      ..clear()
      ..addAll(strokes);
    notifyListeners();
  }

  void clear() {
    _strokes.clear();
    notifyListeners();
  }
}
