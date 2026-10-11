import 'package:flutter/material.dart';
import '../l10n.dart';

import '../config.dart';

/// Progress towards the ₹30,000 minimum order, with the amount reached so far
/// (owner, 11-Oct-2026: show "₹12,000 / ₹30,000").
class MinOrderBar extends StatelessWidget {
  final double progress;
  final bool below;
  final bool compact;

  /// Value reached so far (Σ price × pieces) — shown as "₹12,000 / ₹30,000".
  final int amount;

  /// Open add-on window: "Adding to your parcel …" instead of the minimum.
  final String? addOnTo;
  final String? addOnUntil;
  const MinOrderBar({
    super.key,
    required this.progress,
    required this.below,
    required this.amount,
    this.compact = false,
    this.addOnTo,
    this.addOnUntil,
  });

  static String get minLabel => _rupees(kMinOrderValue);

  static String _rupees(int v) {
    final s = v.toString();
    if (s.length <= 3) return '₹$s';
    final last3 = s.substring(s.length - 3);
    var rest = s.substring(0, s.length - 3);
    final parts = <String>[];
    while (rest.length > 2) {
      parts.insert(0, rest.substring(rest.length - 2));
      rest = rest.substring(0, rest.length - 2);
    }
    if (rest.isNotEmpty) parts.insert(0, rest);
    return '₹${parts.join(',')},$last3';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (addOnTo != null) {
      const g = Color(0xFF2E7D32);
      return Container(
        width: double.infinity,
        padding: EdgeInsets.all(compact ? 8 : 12),
        decoration: BoxDecoration(
          color: g.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: g.withValues(alpha: 0.35)),
        ),
        child: Text(
          '➕ Adding to your parcel $addOnTo — no minimum until ${addOnUntil ?? 'tomorrow 11:59 PM'}.',
          style: TextStyle(
              color: g, fontWeight: FontWeight.w700, fontSize: compact ? 12 : 13),
        ),
      );
    }
    const ok = Color(0xFF2E7D32);
    // Green ONLY when the value really reached the minimum (owner: it said
    // "reached" at ₹10,405 when a design had no readable price).
    final done = amount >= kMinOrderValue;
    // Owner: above ₹30,000 just show the amount — nothing else.
    if (done) {
      return Container(
        width: double.infinity,
        padding: EdgeInsets.symmetric(horizontal: 14, vertical: compact ? 10 : 14),
        decoration: BoxDecoration(
          color: ok.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: ok.withValues(alpha: 0.35)),
        ),
        child: Text(
          'Approx amount ${_rupees(amount)}',
          textAlign: TextAlign.center,
          style: TextStyle(
              color: ok, fontWeight: FontWeight.w900, fontSize: compact ? 16 : 18),
        ),
      );
    }
    const unsure = false;
    final color = done ? ok : const Color(0xFFD32F2F); // red below ₹30,000
    return Container(
      padding: EdgeInsets.all(compact ? 8 : 12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  done
                      ? t('✓ Minimum order $minLabel reached', '✓ कम से कम $minLabel पूरा हो गया')
                      : t('First complete $minLabel — select more designs', 'पहले $minLabel पूरा करें — और डिज़ाइन चुनें'),
                  style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: color,
                      fontSize: compact ? 12 : 13),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '${_rupees(amount)} / $minLabel',
                style: TextStyle(
                    fontWeight: FontWeight.w800,
                    color: color,
                    fontSize: compact ? 12 : 13),
              ),
            ],
          ),
          if (unsure) ...[
            const SizedBox(height: 4),
            Text(
              t('Some designs have no price — we will check the total.',
                  'कुछ डिज़ाइन की कीमत नहीं पढ़ी — कुल रकम हम जाँच लेंगे।'),
              style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
            ),
          ],
          if (!compact && !done && !unsure) ...[
            const SizedBox(height: 4),
            Text(
              t('Below $minLabel our billing computer cannot make a bill. Add more designs or increase pieces.',
                  '$minLabel से कम का बिल हमारे कंप्यूटर में नहीं बनता। और डिज़ाइन या पीस जोड़ें।'),
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
          ],
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: done ? 1 : progress,
              minHeight: compact ? 5 : 7,
              color: color,
              backgroundColor: color.withValues(alpha: 0.15),
            ),
          ),
        ],
      ),
    );
  }
}
