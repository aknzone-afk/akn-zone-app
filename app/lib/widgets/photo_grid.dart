import 'package:catalog_app/widgets/caps_text.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../models/photo.dart';
import '../providers/providers.dart';
import '../services/picks_service.dart';
import 'photo_card.dart';
import 'prefetch_wrap.dart';

/// Uniform grid (saree photos are mostly portrait; consistent tiles read cleaner
/// than a masonry layout without intrinsic dimensions).
class PhotoGrid extends ConsumerWidget {
  final List<Photo> photos;
  final ScrollController? controller;
  final EdgeInsetsGeometry padding;

  /// When true (Cart screen), each card's toggle shows a cross (×) instead of
  /// a tick so the action of tapping is clearly "remove from cart".
  final bool removeMode;

  const PhotoGrid({
    super.key,
    required this.photos,
    this.controller,
    this.padding = const EdgeInsets.fromLTRB(8, 8, 8, 96),
    this.removeMode = false,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (photos.isEmpty) return const _Empty();
    final selection = ref.watch(selectionProvider);
    // Tester 13-Oct: the cart (removeMode) has no multi-select bar, so a hold
    // there used to tick photos with no way to use or leave it, and every tap
    // then only toggled a tick instead of opening SELECT COLOURS / SETS.
    // The cart never enters selection mode now.
    final selectionMode = !removeMode && selection.isNotEmpty;

    final allIds = photos.map((p) => p.id).toList(growable: false);
    WidgetsBinding.instance
        .addPostFrameCallback((_) => prioritizePriceCheck(allIds));
    final urls = photos.map((p) => p.thumbUrl()).toList(growable: false);
    return PrefetchOnChange(
      urls: urls,
      child: GridView.builder(
        controller: controller,
        padding: padding,
        // Big cacheExtent keeps the next ~5 rows of widgets alive off-screen
        // so they're already painted by the time the user scrolls there.
        cacheExtent: 2400,
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 200,
          mainAxisSpacing: 8,
          crossAxisSpacing: 8,
          childAspectRatio: 0.66,
        ),
        itemCount: photos.length,
        itemBuilder: (context, i) {
          final p = photos[i];
          return ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: PhotoCard(
              photo: p,
              removeMode: removeMode,
              selectionMode: selectionMode,
              selected: selection.contains(p.id),
              // In the cart a tap opens TAP-TO-SELECT (tap colours / sets).
              // Owner 12-Oct: a tap on ANY photo opens SELECT COLOURS / SETS
              // straight away — no preview.
              onTap: () => true
                  ? context.push('/pick/${Uri.encodeComponent(p.id)}')
                  : context.push(
                      '/photo/${Uri.encodeComponent(p.id)}',
                      // Owner 12-Oct: swiping skips designs already selected
                      // (they open straight into their selection instead).
                      extra: [
                        for (final id in allIds)
                          if (id == p.id || !_isPicked(ref, id)) id
                      ],
                    ),
              onLongPress: removeMode
                  ? () {}
                  : () => ref.read(selectionProvider.notifier).toggle(p.id),
              onSelectToggle: () =>
                  ref.read(selectionProvider.notifier).toggle(p.id),
            ),
          );
        },
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty();
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.image_search_outlined,
                size: 48, color: Theme.of(context).colorScheme.outline),
            const SizedBox(height: 12),
            UText(
              'No photos match these filters.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }
}

bool _isPicked(WidgetRef ref, String id) {
  if (!ref.read(favoritesProvider).contains(id)) return false;
  final pk = ref.read(picksProvider)[id];
  return pk != null && !pk.isEmpty;
}
