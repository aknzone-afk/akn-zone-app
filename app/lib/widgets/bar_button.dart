import 'package:flutter/material.dart';

/// A boxed top-bar button: icon + word in a rounded outline, so it plainly
/// looks tappable (owner 11-Oct-2026: "clear, roomy, luxurious").
class BarButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap; // null = greyed out
  final int count;
  final bool dot;
  final Color? color;

  /// For black screens (the selection screen): dark box, light outline.
  final bool dark;

  /// Icon above the word (narrow home bar with four buttons).
  final bool stacked;

  /// Small second line under the word, e.g. "(How to order)".
  final String? sub;
  const BarButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.count = 0,
    this.dot = false,
    this.color,
    this.dark = false,
    this.stacked = false,
    this.sub,
  });

  @override
  Widget build(BuildContext context) {
    var fg = color ?? (dark ? Colors.white : const Color(0xFF1B1A18));
    if (onTap == null) fg = fg.withValues(alpha: 0.35);
    return Material(
      color: dark ? const Color(0xFF1E1E1E) : Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: fg.withValues(alpha: 0.55), width: 1.2),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: stacked
            ? SizedBox(
                height: sub != null ? 56 : 50,
                child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Badge(
                    isLabelVisible: count > 0 || dot,
                    smallSize: 8,
                    label: count > 0 ? Text('$count') : null,
                    backgroundColor: const Color(0xFF1B8E3A),
                    child: Icon(icon, size: 21, color: fg),
                  ),
                  const SizedBox(height: 3),
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(label,
                        maxLines: 1,
                        style: TextStyle(
                            color: fg, fontSize: 10.5, fontWeight: FontWeight.w800, letterSpacing: 0.6)),
                  ),
                  if (sub != null)
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(sub!,
                          maxLines: 1,
                          style: TextStyle(color: fg.withValues(alpha: 0.75), fontSize: 8.5, fontWeight: FontWeight.w700)),
                    ),
                ]),
              )
            : SizedBox(
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
