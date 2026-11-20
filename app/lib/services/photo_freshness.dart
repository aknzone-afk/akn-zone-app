import 'package:cached_network_image/cached_network_image.dart';
import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

import '../config.dart';
import 'drive_urls.dart';

/// `drive.google.com/thumbnail?id=X&sz=wN` does nothing but redirect to this
/// address on Google's image host — the same bytes and the same version tag
/// (checked 20-Nov-2026). Null for any other URL.
String? driveDirectUrl(String url) {
  final u = Uri.tryParse(url);
  if (u == null || u.host != 'drive.google.com' || u.path != '/thumbnail') return null;
  final id = u.queryParameters['id'] ?? '';
  final sz = u.queryParameters['sz'] ?? '';
  if (!RegExp(r'^[A-Za-z0-9_-]{10,}$').hasMatch(id)) return null;
  return 'https://lh3.googleusercontent.com/d/$id${RegExp(r'^[whs]\d+$').hasMatch(sz) ? '=$sz' : ''}';
}

/// The addresses to try for one photo, in order.
///
/// 20-Nov: Drive's front door answered thumbnails with 504 / 429 or dropped
/// the connection (300+ error reports in three weeks) and the tile then stayed
/// broken. A Drive photo is now asked for at the image host directly (one
/// round trip less for every photo), then through Drive, then direct once
/// more; anything else gets one second try.
List<String> photoFetchOrder(String url) {
  final direct = driveDirectUrl(url);
  return direct == null ? [url, url] : [direct, url, direct];
}

/// Fetches through [photoFetchOrder]; the cache key stays the URL the app
/// asked for, so every photo already on the phone stays valid.
class PatientFileService extends FileService {
  PatientFileService([FileService? inner]) : _inner = inner ?? HttpFileService();
  final FileService _inner;

  @override
  Future<FileServiceResponse> get(String url, {Map<String, String>? headers}) async {
    final order = photoFetchOrder(url);
    FileServiceResponse? refused;
    Object? error;
    StackTrace? stack;
    for (var i = 0; i < order.length; i++) {
      if (i > 0) await Future<void>.delayed(Duration(milliseconds: 350 * i));
      try {
        final r = await _inner.get(order[i], headers: headers);
        if (r.statusCode == 200 || r.statusCode == 201 || r.statusCode == 304) return r;
        if (r.statusCode == 404) return r; // the photo is gone from Drive — asking again changes nothing
        refused = r; // 429 / 5xx: let the body go and try the next address
        r.content.drain<void>().catchError((_) {});
      } catch (e, s) {
        error = e;
        stack = s;
      }
    }
    if (refused != null) return refused; // the cache manager reports its status as before
    Error.throwWithStackTrace(error!, stack!);
  }
}

class _PhotoCacheManager extends CacheManager with ImageCacheManager {
  _PhotoCacheManager()
      : super(Config(
          // Same store as DefaultCacheManager, so already-downloaded photos
          // are kept. Its default 200-file cap made the daily cleanup delete
          // (and the prefetch re-download) most of the ~1,900 cached images.
          DefaultCacheManager.key,
          maxNrOfCacheObjects: 5000,
          fileService: PatientFileService(),
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
