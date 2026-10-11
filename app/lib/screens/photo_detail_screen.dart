import 'package:catalog_app/widgets/caps_text.dart';
import 'dart:typed_data';
import '../l10n.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:photo_view/photo_view.dart';
import 'package:photo_view/photo_view_gallery.dart';

import '../config.dart';
import '../models/photo.dart';
import '../providers/providers.dart';
import '../services/drive_urls.dart';
import '../services/photo_freshness.dart';
import '../services/price_check.dart';
import '../services/price_ocr.dart';

/// Swipeable full-screen photo viewer. The user can swipe left/right to step
/// through whatever list of photos they were just browsing (folder, search,
/// favorites). The PageView's initial page is [initialPhotoId]; if the id
/// isn't in [photoIds] it falls back to a single-photo view.
class PhotoDetailScreen extends ConsumerStatefulWidget {
  final String initialPhotoId;
  final List<String> photoIds;
  const PhotoDetailScreen({
    super.key,
    required this.initialPhotoId,
    required this.photoIds,
  });

  @override
  ConsumerState<PhotoDetailScreen> createState() => _PhotoDetailScreenState();
}

class _PhotoDetailScreenState extends ConsumerState<PhotoDetailScreen> {
  late final PageController _pageCtrl;
  late int _currentIndex;
  late final List<String> _ids;

  @override
  void initState() {
    super.initState();
    _ids = widget.photoIds.isEmpty ? [widget.initialPhotoId] : widget.photoIds;
    final found = _ids.indexOf(widget.initialPhotoId);
    _currentIndex = found < 0 ? 0 : found;
    _pageCtrl = PageController(initialPage: _currentIndex);
    photoImageEpoch.addListener(_onImagesEvicted);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _prefetchAdjacent(_currentIndex);
      _recheckCurrentPrice();
    });
  }

  /// Photos already checked against Drive while this viewer is open.
  final Set<String> _checked = {};

  void _recheckCurrentPrice() {
    final id = _ids[_currentIndex];
    if (!_checked.add(id)) return;
    final photo = {for (final p in ref.read(photosProvider)) p.id: p}[id];
    if (photo != null) _refreshIfReplaced(photo);
  }

  /// If this photo's file was replaced on Drive since its price was read (or
  /// its re-read is still queued), drop the old pictures and read the price
  /// from the current file right away.
  Future<void> _refreshIfReplaced(Photo photo) async {
    // Captured up front: the catalog must refresh even if the viewer closes.
    final container = ProviderScope.containerOf(context, listen: false);
    final dio = container.read(dioProvider);
    final cache = container.read(localCacheProvider);
    final r = await fetchDriveVersion(dio, photo.id);
    final live = r.version;
    if (live == null) return;
    container.read(priceCheckProvider.notifier).record(photo.id, live);
    final replaced = live != photo.driveVersion;
    final queued = photo.ocrState != OcrState.done && !photo.priceFromFolder;
    if (!replaced && !queued) return;
    if (replaced) {
      final outdated = photo.driveVersion != null ||
          await hasOutdatedCachedImage(photo.id, live);
      await forgetOutdatedPictures(
          container, {if (outdated) photo.id}, {photo.id: live});
    }
    if (photo.priceFromFolder) {
      await cache.saveDriveVersions({photo.id: live});
    } else {
      final ocr = PriceOcr(dio: dio);
      try {
        final r = await ocr.recognize(photo.id);
        if (r.ok) {
          final seedMap = await container.read(seedLoaderProvider).load();
          final seedEntry = seedMap[photo.id];
          final s = (seedEntry != null &&
                  seedEntry.price != null &&
                  seedEntry.ocrText.isNotEmpty &&
                  seedEntry.driveVersion == (r.version ?? live))
              ? seedEntry
              : null;
          await cache.saveOcr(
            photoId: photo.id,
            fabricName: null,
            price: s?.price ?? r.price,
            priceText: s?.priceText ?? r.priceText,
            ocrText: s?.ocrText ?? r.text,
            state: OcrState.done,
            driveVersion: r.version ?? live,
          );
        } else {
          await cache
              .saveDriveVersions({photo.id: live}, needsReread: {photo.id});
        }
      } catch (_) {
        await cache
            .saveDriveVersions({photo.id: live}, needsReread: {photo.id});
      } finally {
        ocr.close();
      }
    }
    container.invalidate(catalogProvider);
  }

  void _prefetchAdjacent(int around) {
    for (final delta in const [-2, -1, 1, 2]) {
      final idx = around + delta;
      if (idx < 0 || idx >= _ids.length) continue;
      // ignore: discarded_futures
      _warm(DriveUrls.thumbnail(_ids[idx], width: kDetailImageWidth));
    }
  }

  Future<void> _warm(String url) async {
    try {
      if (await photoCacheManager.getFileFromCache(url) != null) return;
      await photoCacheManager.downloadFile(url);
    } catch (_) {}
  }

  void _onImagesEvicted() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    photoImageEpoch.removeListener(_onImagesEvicted);
    _pageCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final photos = ref.watch(photosProvider);
    final byId = <String, Photo>{for (final p in photos) p.id: p};
    final currentPhoto = byId[_ids[_currentIndex]];

    if (currentPhoto == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: UText('Photo not found.')),
      );
    }

    final isFav = ref.watch(favoritesProvider).contains(currentPhoto.id);
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: UText(
                currentPhoto.designNumber ?? currentPhoto.filename,
                overflow: TextOverflow.ellipsis,
                // Force bright white — a theme titleTextStyle was rendering it dull.
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            if (_ids.length > 1) ...[
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.white12,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: UText(
                  '${_currentIndex + 1}/${_ids.length}',
                  style: const TextStyle(fontSize: 11, color: Colors.white70),
                ),
              ),
            ],
          ],
        ),
        actions: [
          // Owner, 11-Oct-2026: one clear box instead of cart / edit icons.
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: isFav ? const Color(0xFF1B8E3A) : Colors.white,
                foregroundColor: isFav ? Colors.white : Colors.black,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8)),
              ),
              // Replace this view, so DONE returns straight to the folder.
              onPressed: () => context.pushReplacement(
                  '/pick/${Uri.encodeComponent(currentPhoto.id)}'),
              child: Text(isFav ? t('✓ SELECTED', '✓ सिलेक्ट हो गया') : t('DO SELECTION', 'सिलेक्ट करें'),
                  style: const TextStyle(
                      fontWeight: FontWeight.w900, letterSpacing: 0.8)),
            ),
          ),
          const SizedBox(width: 6),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            // PhotoViewGallery (instead of a raw PageView) resolves the
            // zoom-vs-swipe gesture conflict properly: while zoomed in, a drag
            // PANS the photo; only at normal zoom does a drag swipe pages.
            child: PhotoViewGallery.builder(
              pageController: _pageCtrl,
              itemCount: _ids.length,
              backgroundDecoration: const BoxDecoration(color: Colors.black),
              onPageChanged: (i) {
                setState(() => _currentIndex = i);
                _prefetchAdjacent(i);
                _recheckCurrentPrice();
              },
              loadingBuilder: (_, ev) => Center(
                child: CircularProgressIndicator(
                  value: ev?.expectedTotalBytes == null
                      ? null
                      : (ev!.cumulativeBytesLoaded / ev.expectedTotalBytes!),
                  color: Colors.white,
                ),
              ),
              builder: (context, i) {
                final photo = byId[_ids[i]];
                if (photo == null) {
                  return PhotoViewGalleryPageOptions.customChild(
                    child: const Center(
                      child: Icon(Icons.broken_image_outlined,
                          color: Colors.white, size: 56),
                    ),
                  );
                }
                // Re-read edits for each page so the edited preview swaps in
                // immediately after a save.
                final edits = ref.watch(editsProvider);
                final editVersion = edits[photo.id];
                if (editVersion != null) {
                  return PhotoViewGalleryPageOptions.customChild(
                    child: _EditedPhotoView(
                      key: ValueKey('edit-${photo.id}-$editVersion'),
                      photoId: photo.id,
                    ),
                  );
                }
                final fullUrl = photo.detailUrl();
                return PhotoViewGalleryPageOptions(
                  imageProvider: RefreshableNetworkImage(fullUrl),
                  minScale: PhotoViewComputedScale.contained,
                  maxScale: PhotoViewComputedScale.covered * 8,
                  errorBuilder: (_, __, ___) => const Center(
                    child: Icon(Icons.broken_image_outlined,
                        color: Colors.white, size: 56),
                  ),
                );
              },
            ),
          ),
          _DetailFooter(
            photo: currentPhoto,
            price: ref.watch(priceCheckProvider
                .select((s) => priceDisplayFor(currentPhoto, s))),
            scheme: scheme,
          ),
        ],
      ),
    );
  }
}

class _DetailFooter extends StatelessWidget {
  final Photo photo;
  final PriceDisplay price;
  final ColorScheme scheme;
  const _DetailFooter(
      {required this.photo, required this.price, required this.scheme});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black,
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 18),
      child: SafeArea(
        top: false,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (photo.fabricName != null)
                    UText(
                      photo.fabricName!,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                        fontSize: 16,
                      ),
                    ),
                  const SizedBox(height: 2),
                  Wrap(
                    spacing: 12,
                    runSpacing: 2,
                    children: [
                      if (photo.designNumber != null)
                        _Meta(label: 'Design', value: photo.designNumber!),
                      if (photo.folder.isNotEmpty)
                        _Meta(label: 'Folder', value: photo.folder),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            if (price != PriceDisplay.none)
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: scheme.primaryContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: UText(
                  priceLabel(photo, price),
                  style: TextStyle(
                    color: scheme.onPrimaryContainer,
                    fontWeight: FontWeight.w800,
                    fontSize: 18,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Meta extends StatelessWidget {
  final String label;
  final String value;
  const _Meta({required this.label, required this.value});
  @override
  Widget build(BuildContext context) {
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: '$label: ',
            style: const TextStyle(
                color: Colors.white60,
                fontSize: 14,
                fontWeight: FontWeight.w500),
          ),
          TextSpan(
            text: value,
            style: const TextStyle(
                color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}

/// Full-screen viewer for a photo that has a locally-saved markup edit. Reads
/// the PNG bytes from disk and feeds them into PhotoView as a MemoryImage so
/// the user sees the version they actually edited (not the original Drive
/// thumbnail).
class _EditedPhotoView extends ConsumerStatefulWidget {
  final String photoId;
  const _EditedPhotoView({super.key, required this.photoId});

  @override
  ConsumerState<_EditedPhotoView> createState() => _EditedPhotoViewState();
}

class _EditedPhotoViewState extends ConsumerState<_EditedPhotoView> {
  Uint8List? _bytes;
  bool _missing = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final data = await ref.read(editServiceProvider).read(widget.photoId);
    if (!mounted) return;
    setState(() {
      _bytes = data;
      _missing = data == null || data.isEmpty;
    });
  }

  @override
  Widget build(BuildContext context) {
    final b = _bytes;
    if (_missing) {
      return const Center(
        child: Icon(Icons.broken_image_outlined, color: Colors.white, size: 56),
      );
    }
    if (b == null) {
      return const Center(
        child: CircularProgressIndicator(color: Colors.white),
      );
    }
    return PhotoView(
      imageProvider: MemoryImage(b),
      minScale: PhotoViewComputedScale.contained,
      maxScale: PhotoViewComputedScale.covered * 8,
      backgroundDecoration: const BoxDecoration(color: Colors.black),
      errorBuilder: (_, __, ___) => const Center(
        child: Icon(Icons.broken_image_outlined, color: Colors.white, size: 56),
      ),
    );
  }
}
