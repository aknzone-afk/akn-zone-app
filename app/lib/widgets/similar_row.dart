import 'dart:convert';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../config.dart';
import '../models/photo.dart';
import '../providers/providers.dart';
import '../services/photo_freshness.dart';

/// "Similar designs" (owner, 11-Oct-2026): look-alike designs from the
/// Design Finder's fingerprints, published daily as app/similar.json.
final similarProvider = FutureProvider<Map<String, List<String>>>((ref) async {
  final prefs = ref.watch(sharedPreferencesProvider);
  const k = 'similar_v1';
  Map<String, List<String>> parse(String s) {
    final j = jsonDecode(s) as Map<String, dynamic>;
    return (j['similar'] as Map).map((k, v) =>
        MapEntry('$k', (v as List).map((e) => '$e').toList()));
  }

  try {
    final res = await ref.watch(dioProvider).get<dynamic>(
        '$kDataBase/app/similar.json?t=${DateTime.now().millisecondsSinceEpoch ~/ 3600000}');
    final s = res.data is String ? res.data as String : jsonEncode(res.data);
    await prefs.setString(k, s);
    return parse(s);
  } catch (_) {
    final s = prefs.getString(k);
    return s == null ? {} : parse(s);
  }
});

String _norm(String s) => s.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');

class SimilarRow extends ConsumerWidget {
  final Photo photo;
  const SimilarRow({super.key, required this.photo});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final map = ref.watch(similarProvider).valueOrNull ?? const {};
    final key = _norm(photo.designNumber ?? '');
    final wanted = map[key] ?? const <String>[];
    if (wanted.isEmpty) return const SizedBox.shrink();
    final photos = ref.watch(photosProvider);
    final picks = <Photo>[];
    for (final d in wanted) {
      final hit = photos.where((p) => _norm(p.designNumber ?? '') == d).firstOrNull;
      if (hit != null) picks.add(hit);
    }
    if (picks.isEmpty) return const SizedBox.shrink();
    return Container(
      color: Colors.black,
      padding: const EdgeInsets.fromLTRB(12, 6, 0, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('SIMILAR DESIGNS',
              style: TextStyle(
                  color: Colors.white70,
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1)),
          const SizedBox(height: 6),
          SizedBox(
            height: 92,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: picks.length,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (_, i) {
                final p = picks[i];
                return GestureDetector(
                  onTap: () => context.push('/photo/${Uri.encodeComponent(p.id)}',
                      extra: picks.map((e) => e.id).toList()),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Stack(children: [
                      CachedNetworkImage(
                        imageUrl: p.thumbUrl(),
                        cacheManager: photoCacheManager,
                        width: 92,
                        height: 92,
                        memCacheWidth: 240,
                        fit: BoxFit.cover,
                      ),
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        child: Container(
                          color: Colors.black54,
                          padding: const EdgeInsets.symmetric(vertical: 2),
                          child: Text(p.designNumber ?? '',
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                  color: Colors.white, fontSize: 10, fontWeight: FontWeight.w700)),
                        ),
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
}
