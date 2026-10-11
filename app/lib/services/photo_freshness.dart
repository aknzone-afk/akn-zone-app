import 'package:cached_network_image/cached_network_image.dart';
import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

import '../config.dart';
import 'drive_urls.dart';

class _PhotoCacheManager extends CacheManager with ImageCacheManager {
  _PhotoCacheManager()
      : super(Config(
          // Same store as DefaultCacheManager, so already-downloaded photos
          // are kept. Its default 200-file cap made the daily cleanup delete
          // (and the prefetch re-download) most of the ~1,900 cached images.
          DefaultCacheManager.key,
          maxNrOfCacheObjects: 5000,
        ));
}

/// The one image cache every Drive photo goes through. Never mix it with
/// DefaultCacheManager(): that instance would prune the shared store to 200.
final CacheManager photoCacheManager = _PhotoCacheManager();

/// Drive's ETag is the file's version ("v7"); strip quoting and the weak
/// prefix so the same version always compares equal.
String? normalizeEtag(String? raw) {
  if (raw == null) return null;
  var v = raw.trim();
  if (v.startsWith('W/')) v = v.substring(2);
  v = v.replaceAll('"', '').trim();
  return v.isEmpty ? null : v;
}

/// Result of a Drive version check: the version if reachable, plus whether the
/// server was reached at all (a 404 is reached but has no version; a timeout is
/// not reached).
typedef DriveVersionResult = ({String? version, bool reached});

/// Current Drive version of [fileId]. [reached] is true when Drive responded
/// (even with 404); false on timeout/connection error.
Future<DriveVersionResult> fetchDriveVersion(Dio dio, String fileId) async {
  try {
    final res = await dio.head<void>(
      DriveUrls.content(fileId),
      options: Options(receiveTimeout: const Duration(seconds: 15)),
    );
    return (version: normalizeEtag(res.headers.value('etag')), reached: true);
  } on DioException catch (e) {
    return (version: null, reached: e.response != null);
  } catch (_) {
    return (version: null, reached: false);
  }
}

/// Drive version of the image cached for [url], if one is cached.
Future<String?> cachedImageVersion(String url) async {
  final o = await photoCacheManager.store.retrieveCacheData(url);
  return o == null ? null : normalizeEtag(o.eTag) ?? '';
}

/// True when a cached grid or full-size image of [fileId] came from a
/// different Drive version than [liveVersion].
Future<bool> hasOutdatedCachedImage(String fileId, String liveVersion) async {
  for (final width in const [kThumbnailWidth, kDetailImageWidth]) {
    final v =
        await cachedImageVersion(DriveUrls.thumbnail(fileId, width: width));
    if (v != null && v != liveVersion) return true;
  }
  return false;
}

/// Pixel width to decode a grid tile's thumbnail at: tiles are at most ~220pt
/// wide, so decoding the full 600px image on a 2x phone just wastes memory.
int gridDecodeWidth(BuildContext context) =>
    (220 * MediaQuery.devicePixelRatioOf(context))
        .round()
        .clamp(1, kThumbnailWidth);

/// Bumped whenever replaced photos are evicted. On-screen image widgets key on
/// it (see [PhotoImageRefresh]) because an image widget whose URL didn't change
/// keeps showing its already-decoded picture.
final ValueNotifier<int> photoImageEpoch = ValueNotifier<int>(0);

/// Rebuilds [child] from scratch after an eviction so it loads the new image.
class PhotoImageRefresh extends StatelessWidget {
  final Widget child;
  const PhotoImageRefresh({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: photoImageEpoch,
      builder: (_, epoch, __) =>
          KeyedSubtree(key: ValueKey(epoch), child: child),
    );
  }
}

/// Forgets every on-device copy of these photos so the grid and viewer fetch
/// the replaced image instead of showing the old one.
Future<void> evictPhotoImages(Iterable<String> fileIds) async {
  var any = false;
  for (final id in fileIds) {
    any = true;
    for (final width in const [kThumbnailWidth, kDetailImageWidth]) {
      try {
        await photoCacheManager
            .removeFile(DriveUrls.thumbnail(id, width: width));
      } catch (_) {}
    }
  }
  if (!any) return;
  // Decoded images are keyed by URL (and by resize for small tiles), so clear
  // the in-memory cache wholesale; visible tiles re-decode from disk.
  PaintingBinding.instance.imageCache
    ..clear()
    ..clearLiveImages();
  photoImageEpoch.value++;
}

/// A [CachedNetworkImageProvider] that also counts as a new image after an
/// eviction, so a widget holding it re-resolves. The cache key is unchanged.
class RefreshableNetworkImage
    extends ImageProvider<CachedNetworkImageProvider> {
  RefreshableNetworkImage(String url)
      : inner =
            CachedNetworkImageProvider(url, cacheManager: photoCacheManager),
        epoch = photoImageEpoch.value;

  final CachedNetworkImageProvider inner;
  final int epoch;

  @override
  Future<CachedNetworkImageProvider> obtainKey(
          ImageConfiguration configuration) =>
      inner.obtainKey(configuration);

  @override
  ImageStreamCompleter loadImage(
          CachedNetworkImageProvider key, ImageDecoderCallback decode) =>
      inner.loadImage(key, decode);

  @override
  bool operator ==(Object other) =>
      other is RefreshableNetworkImage &&
      other.inner == inner &&
      other.epoch == epoch;

  @override
  int get hashCode => Object.hash(inner, epoch);
}
