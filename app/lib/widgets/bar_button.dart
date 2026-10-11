import 'package:flutter/material.dart';

/// A boxed top-bar button: icon + word in a rounded outline, so it plainly
/// looks tappable (owner 11-Oct-2026: "clear, roomy, luxurious").
class BarButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final int count;
  final bool dot;
  final Color? color;
  const BarButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.count = 0,
    this.dot = false,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final fg = color ?? const Color(0xFF1B1A18);
    return Material(
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: fg.withValues(alpha: 0.55), width: 1.2),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: SizedBox(
          height: 42,
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            Badge(
              isLabelVisible: count > 0 || dot,
              smallSize: 8,
              label: count > 0 ? Text('$count') : null,
              backgroundColor: const Color(0xFF1B8E3A),
              child: Icon(icon, size: 20, color: fg),
            ),
            const SizedBox(width: 6),
            Flexible(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(label,
                    maxLines: 1,
                    style: TextStyle(
                        color: fg, fontSize: 13, fontWeight: FontWeight.w800, letterSpacing: 0.8)),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}
