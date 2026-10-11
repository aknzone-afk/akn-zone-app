import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../config.dart';
import '../models/folder.dart';
import '../services/drive_urls.dart';
import '../services/photo_freshness.dart';

/// "Pile of photos" cover for a folder tile: the cover photo in front with up
/// to three real photos from the folder fanned out at slight angles behind it
/// — so customers immediately see it's a folder of designs, not one image.
/// Used by the home grid and by sub-folder tiles so all folders look alike.
class PhotoStack extends StatelessWidget {
  final CatalogFolder folder;
  const PhotoStack({super.key, required this.folder});

  /// Half-hidden back cards decode the shared thumbnail smaller to save memory.
  Widget _photoCard(BuildContext context, String id,
      {required double angle, int? decodeWidth = 300}) {
    final scheme = Theme.of(context).colorScheme;
    return Transform.rotate(
      angle: angle,
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(5),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.16),
              blurRadius: 7,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        padding: const EdgeInsets.all(3),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: CachedNetworkImage(
            imageUrl: DriveUrls.thumbnail(id, width: kThumbnailWidth),
            cacheManager: photoCacheManager,
            memCacheWidth: decodeWidth ?? gridDecodeWidth(context),
            fit: BoxFit.cover,
            fadeInDuration: const Duration(milliseconds: 120),
            placeholder: (_, __) =>
                ColoredBox(color: scheme.surfaceContainerLow),
            errorWidget: (_, __, ___) =>
                ColoredBox(color: scheme.surfaceContainerLow),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cover = folder.coverThumbPath!;
    final previews = folder.previewThumbPaths;
    // Fall back to the cover itself when the folder has few photos, so the
    // stacked-edges look is always there.
    final back1 = previews.isNotEmpty ? previews[0] : cover;
    final back2 = previews.length > 1 ? previews[1] : cover;
    final back3 = previews.length > 2 ? previews[2] : back1;
    return PhotoImageRefresh(
      child: Stack(
        fit: StackFit.expand,
        children: [
          Positioned.fill(child: _photoCard(context, back3, angle: 0.12)),
          Positioned.fill(child: _photoCard(context, back2, angle: -0.085)),
          Positioned.fill(child: _photoCard(context, back1, angle: 0.055)),
          Positioned.fill(
              child: _photoCard(context, cover, angle: 0.0, decodeWidth: null)),
        ],
      ),
    );
  }
}
