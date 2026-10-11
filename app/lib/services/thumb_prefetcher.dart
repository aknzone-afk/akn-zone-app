import 'photo_freshness.dart';

/// Warms the shared `cached_network_image` disk cache so scrolling a photo
/// grid never shows blank tiles for more than the briefest of moments.
///
/// Behaviour:
///   - Called repeatedly is safe — already-cached URLs are skipped (no
///     network roundtrip).
///   - Runs in the background; UI never blocks waiting for it.
class ThumbPrefetcher {
  static final _mgr = photoCacheManager;

  /// Download every URL in [urls] into the shared cache, up to [concurrency]
  /// at a time. Errors per URL are silently ignored.
  static Future<void> warmCache(
    Iterable<String> urls, {
    int concurrency = 8,
  }) async {
    final queue = urls.toList();
    Future<void> worker() async {
      while (queue.isNotEmpty) {
        final url = queue.removeAt(0);
        try {
          // downloadFile always hits the network (a conditional request), so
          // skip what's already on disk.
          if (await _mgr.getFileFromCache(url) != null) continue;
          await _mgr.downloadFile(url).timeout(const Duration(seconds: 60));
        } catch (_) {/* missing thumb is non-fatal */}
      }
    }

    await Future.wait(List.generate(concurrency, (_) => worker()));
  }
}
