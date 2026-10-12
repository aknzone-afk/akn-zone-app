import 'package:catalog_app/widgets/caps_text.dart';
import 'dart:typed_data';
import '../l10n.dart';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../models/photo.dart';
import '../providers/providers.dart';
import '../services/photo_freshness.dart';
import '../services/picks_service.dart';
import '../services/pieces_service.dart';
import 'pick_preview.dart';
import '../services/price_check.dart';

class PhotoCard extends ConsumerWidget {
  final Photo photo;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final bool selectionMode;
  final bool selected;
  final VoidCallback onSelectToggle;

  /// When `true`, the toggle icon shows a cross (×) instead of a tick so the
  /// user understands tapping removes the photo from the cart. Used by the
  /// Cart screen.
  final bool removeMode;

  const PhotoCard({
    super.key,
    required this.photo,
    required this.onTap,
    required this.onLongPress,
    required this.selectionMode,
    required this.selected,
    required this.onSelectToggle,
    this.removeMode = false,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isFav = ref.watch(favoritesProvider).contains(photo.id);
    final price =
        ref.watch(priceCheckProvider.select((s) => priceDisplayFor(photo, s)));
    final edits = ref.watch(editsProvider);
    final editVersion = edits[photo.id];
    final isEdited = editVersion != null;
    final scheme = Theme.of(context).colorScheme;
    final pick = isFav ? ref.watch(picksProvider)[photo.id] : null;
    ref.watch(piecesProvider);
    final count = ref.read(piecesProvider.notifier).piecesFor(photo);
    final String? pickLabel =
        (pick == null || pick.isEmpty) ? null : pick.label(count);
    final String? pickSummary =
        (pick == null || pick.isEmpty) ? null : pick.summary(count);

    return GestureDetector(
      // Owner 11-Oct: a SELECTED design opens straight into its selection
      // (numbers / SETS) for editing — not the plain photo view.
      onTap: selectionMode
          ? onSelectToggle
          : (pickLabel != null
              ? () => context.push('/pick/${Uri.encodeComponent(photo.id)}')
              : onTap),
      onLongPress: onLongPress,
      // Owner 11-Oct: the select box sits UNDER the photo (not on it), so the
      // rate and design no. stay visible on the picture.
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Expanded(
          child: Stack(
        fit: StackFit.expand,
        children: [
          Container(
            color: scheme.surfaceContainerLowest,
            child: pickLabel != null
                ? PickPreviewImage(
                    photo: photo,
                    pick: pick!,
                    sareeCount: count,
                    band: false,
                    decodeWidth: gridDecodeWidth(context),
                  )
                : isEdited
                ? _EditedFileImage(
                    key: ValueKey('edit-${photo.id}-$editVersion'),
                    photoId: photo.id,
                  )
                : PhotoImageRefresh(
                    child: CachedNetworkImage(
                      imageUrl: photo.thumbUrl(),
                      cacheManager: photoCacheManager,
                      memCacheWidth: gridDecodeWidth(context),
                      fit: BoxFit.cover,
                      fadeInDuration: const Duration(milliseconds: 120),
                      placeholder: (_, __) => const _Skeleton(),
                      errorWidget: (_, __, ___) => const _BrokenTile(),
                    ),
                  ),
          ),
          // Full selection text, readable, at the bottom of the photo.
          if (pickSummary != null)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Container(
                color: const Color(0xEE111111),
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                child: Text(
                  pickSummary,
                  textAlign: TextAlign.center,
                  maxLines: 3,
                  style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                      fontSize: 11.5,
                      height: 1.25),
                ),
              ),
            ),
          if (pickSummary == null &&
              (price != PriceDisplay.none || photo.designNumber != null))
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: [Color(0xCC000000), Color(0x00000000)],
                  ),
                ),
                padding: const EdgeInsets.fromLTRB(8, 16, 8, 6),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    if (price != PriceDisplay.none) ...[
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.92),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: UText(
                          priceLabel(photo, price),
                          style: const TextStyle(
                            color: Color(0xFF111111),
                            fontWeight: FontWeight.w700,
                            fontSize: 12,
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                    ],
                    if (photo.designNumber != null)
                      Flexible(
                        child: UText(
                          photo.designNumber!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.end,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                            fontSize: 11,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          if (!removeMode && ref.watch(newDesignIdsProvider).contains(photo.id))
            Positioned(
              top: 8,
              left: 8,
              child: IgnorePointer(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                  decoration: BoxDecoration(
                    color: const Color(0xFFD32F2F),
                    borderRadius: BorderRadius.circular(5),
                  ),
                  child: const Text('NEW',
                      style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w900,
                          fontSize: 11,
                          letterSpacing: 0.8)),
                ),
              ),
            ),
          if (selectionMode)
            Positioned(
              top: 4,
              left: 4,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                decoration: BoxDecoration(
                  color: selected ? scheme.primary : Colors.black38,
                  borderRadius: BorderRadius.circular(20),
                ),
                padding: const EdgeInsets.all(4),
                child: Icon(
                  selected ? Icons.check_rounded : Icons.circle_outlined,
                  color: Colors.white,
                  size: 18,
                ),
              ),
            ),
          if (selectionMode && selected)
            Container(color: scheme.primary.withValues(alpha: 0.18)),
        ],
      ),
        ),
        // Joined to the photo — no gap (owner 12-Oct).
        SizedBox(
          height: 40,
          child: Row(
                children: [
                  Expanded(
                    child: Material(
                      color: pickLabel != null
                          ? const Color(0xF21B8E3A)
                          : const Color(0xE61B1A18),
                      child: InkWell(
                        onTap: () {
                          precacheImage(
                              CachedNetworkImageProvider(photo.detailUrl(),
                                  cacheManager: photoCacheManager),
                              context);
                          context.push('/pick/${Uri.encodeComponent(photo.id)}');
                        },
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 8),
                          child: Text(
                            pickLabel != null
                                ? '✓ SELECTED'
                                : (isFav ? t('✓ IN CART · SELECT', '✓ कार्ट में · सिलेक्ट') : t('SELECT COLOURS / SETS', 'सिलेक्ट करें')),
                            textAlign: TextAlign.center,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w800,
                              fontSize: 12,
                              letterSpacing: 0.6,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  if (removeMode) ...[
                    const SizedBox(width: 6),
                    Material(
                      color: const Color(0xE61B1A18),
                      shape: const CircleBorder(),
                      child: InkWell(
                        customBorder: const CircleBorder(),
                        onTap: () async {
                          await ref.read(picksProvider.notifier).remove(photo.id);
                          await ref
                              .read(favoritesProvider.notifier)
                              .toggle(photo.id);
                        },
                        child: const Padding(
                          padding: EdgeInsets.all(7),
                          child: Icon(Icons.close_rounded,
                              size: 20, color: Colors.white),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
        ),
      ]),
    );
  }
}

class _EditedFileImage extends ConsumerStatefulWidget {
  final String photoId;
  const _EditedFileImage({super.key, required this.photoId});

  @override
  ConsumerState<_EditedFileImage> createState() => _EditedFileImageState();
}

class _EditedFileImageState extends ConsumerState<_EditedFileImage> {
  Uint8List? _bytes;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant _EditedFileImage old) {
    super.didUpdateWidget(old);
    if (old.photoId != widget.photoId) _load();
  }

  Future<void> _load() async {
    // Read bytes fresh from disk (not via Image.file, which caches by path
    // and would serve stale pixels after the user re-saves an edit).
    final data = await ref.read(editServiceProvider).read(widget.photoId);
    if (!mounted) return;
    setState(() => _bytes = data);
  }

  @override
  Widget build(BuildContext context) {
    final b = _bytes;
    if (b == null || b.isEmpty) return const _Skeleton();
    return Image.memory(
      b,
      fit: BoxFit.cover,
      gaplessPlayback: true,
    );
  }
}

class _Skeleton extends StatelessWidget {
  const _Skeleton();
  @override
  Widget build(BuildContext context) {
    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      alignment: Alignment.center,
      child: const SizedBox(
        width: 22,
        height: 22,
        child: CircularProgressIndicator(strokeWidth: 2),
      ),
    );
  }
}

class _BrokenTile extends StatelessWidget {
  const _BrokenTile();
  @override
  Widget build(BuildContext context) {
    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      alignment: Alignment.center,
      child: Icon(
        Icons.broken_image_outlined,
        color: Theme.of(context).colorScheme.outline,
      ),
    );
  }
}
