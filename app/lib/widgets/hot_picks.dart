import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../l10n.dart';
import '../models/photo.dart';
import '../providers/providers.dart';
import '../services/model_pics.dart' show modelKey;
import '../services/photo_freshness.dart' show photoCacheManager;
import '../services/stats_service.dart';

/// Owner 27-Oct (4): below ₹30,000 — "add ₹X more", with this week's most
/// popular designs (not already in the cart) one tap away.
class HotPicksRow extends ConsumerWidget {
  final int short; // rupees still needed to reach the minimum
  const HotPicksRow({super.key, required this.short});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hot = Stats.hot(ref.read(sharedPreferencesProvider));
    if (hot.isEmpty) return const SizedBox.shrink();
    final inCart = ref.watch(favoritesProvider);
    final byDesign = <String, Photo>{};
    for (final p in ref.watch(photosProvider)) {
      final k = modelKey(p.designNumber);
      if (k.isEmpty || inCart.contains(p.id)) continue;
      byDesign.putIfAbsent(k, () => p);
    }
    final picks = [for (final d in hot) if (byDesign[modelKey(d)] != null) byDesign[modelKey(d)]!].take(12).toList();
    if (picks.isEmpty) return const SizedBox.shrink();
    final need = short > 0 ? 'Add ₹${_fmt(short)} more — ' : '';
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(t('${need}popular this week 🔥', '${short > 0 ? '₹${_fmt(short)} और जोड़ें — ' : ''}इस हफ़्ते के पसंदीदा 🔥'),
              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14)),
          const SizedBox(height: 6),
          SizedBox(
            height: 150,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: picks.length,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (context, i) {
                final p = picks[i];
                return GestureDetector(
                  onTap: () {
                    Stats.step('hot_tap');
                    context.push('/pick/${Uri.encodeComponent(p.id)}');
                  },
                  child: SizedBox(
                    width: 100,
                    child: Column(children: [
                      Expanded(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: CachedNetworkImage(
                            imageUrl: p.thumbUrl(),
                            cacheManager: photoCacheManager,
                            fit: BoxFit.cover,
                            width: 100,
                            placeholder: (_, __) => const ColoredBox(color: Colors.black12),
                            errorWidget: (_, __, ___) => const ColoredBox(color: Colors.black12),
                          ),
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        p.price == null ? (p.designNumber ?? '') : '₹${p.price} · ${p.designNumber ?? ''}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
                      ),
                    ]),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  static String _fmt(int v) {
    final s = v.toString();
    if (s.length <= 3) return s;
    final last3 = s.substring(s.length - 3);
    var rest = s.substring(0, s.length - 3);
    final parts = <String>[];
    while (rest.length > 2) {
      parts.insert(0, rest.substring(rest.length - 2));
      rest = rest.substring(0, rest.length - 2);
    }
    if (rest.isNotEmpty) parts.insert(0, rest);
    return '${parts.join(',')},$last3';
  }
}
