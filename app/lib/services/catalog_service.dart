import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config.dart';
import '../models/photo.dart';
import 'drive_scraper.dart';
import 'local_cache.dart';
import 'ocr_service.dart';
import 'seed_loader.dart';

class CatalogResult {
  final List<Photo> photos;
  final List<String> folders;
  final DateTime updatedAt;
  final bool fromCache;
  // True when [photos] is the FULL catalog (a complete scrape or a fully-loaded
  // cache) — safe to reconcile the cart against. False for a partial scrape or
  // an error fallback.
  final bool authoritative;
  // True when [photos] came from the bundled seed manifest on a FIRST launch
  // (shown instantly, offline). The provider does a single, sequenced
  // background catch-up for this case instead of the normal concurrent
  // cache-path work, which would OOM-crash a fresh install.
  final bool seeded;
  CatalogResult({
    required this.photos,
    required this.folders,
    required this.updatedAt,
    required this.fromCache,
    this.authoritative = false,
    this.seeded = false,
  });
}

class CatalogServiceException implements Exception {
  final String message;
  CatalogServiceException(this.message);
  @override
  String toString() => message;
}

class CatalogService {
  final DriveScraper _scraper;
  final LocalCache _cache;
  final SharedPreferences _prefs;
  final SeedLoader _seedLoader;

  CatalogService({
    required DriveScraper scraper,
    required LocalCache cache,
    required SharedPreferences prefs,
    required SeedLoader seedLoader,
  })  : _scraper = scraper,
        _cache = cache,
        _prefs = prefs,
        _seedLoader = seedLoader;

  static const _kLastScrapeKey = 'catalog_last_scrape';
  static const _kVerifiedPricesKey = 'bundled_prices_applied';
  static const _kLastTotalFoldersKey = 'catalog_last_total_folders';
  static const _kLastTotalPhotosKey = 'catalog_last_total_photos';
  // Set true only after a FULLY successful scrape. Until then we keep
  // re-scraping on every open, so a network-interrupted first load self-heals.
  static const _kScrapeOkKey = 'catalog_scrape_ok';

  /// Last successful scrape's folder count, so the next load screen can
  /// estimate a percentage. Returns 0 if never scraped.
  int get lastKnownFolderCount => _prefs.getInt(_kLastTotalFoldersKey) ?? 0;

  int get lastKnownPhotoCount => _prefs.getInt(_kLastTotalPhotosKey) ?? 0;

  /// Returns the catalog. First install (cache empty) scrapes Drive
  /// recursively. `force=true` re-scrapes even when cached data exists.
  Future<CatalogResult> load({
    bool force = false,
    void Function(int folders, int photos)? onProgress,
    void Function(DrivePhoto photo)? onPhotoDiscovered,
  }) async {
    await _applyBundledPricesOnce();
    var hasLocal = await _cache.hasPhotos();
    final everFullyLoaded = _prefs.getBool(_kScrapeOkKey) ?? false;
    // Serve whatever is cached. If no scrape has completed yet (network died
    // mid-scrape, or a folder keeps failing), the background re-scan retries
    // every [kCatalogRefreshInterval] instead of blocking every open on a
    // full Drive walk.
    if (!force && hasLocal) {
      final lastMs = _prefs.getInt(_kLastScrapeKey) ?? 0;
      final photos = await _cache.allPhotos();
      final folders = await _cache.allFolders();
      return CatalogResult(
        photos: photos,
        folders: folders,
        updatedAt: DateTime.fromMillisecondsSinceEpoch(lastMs),
        fromCache: true,
        // Only a cache built by a complete scrape is the full set.
        authoritative: everFullyLoaded,
      );
    }

    // FIRST LAUNCH (cache empty): seed the catalog from the bundled
    // `seed_manifest.json` so the app shows a full catalog of designs INSTANTLY
    // — even with no network or a slow/failed Drive scrape. This is the fix for
    // the App Store "minimum functionality" rejection: a fresh review device
    // couldn't reach Drive, so the app looked empty. We return the seeded
    // catalog immediately and refresh from Drive in the background so the live
    // data catches up without ever showing an empty/loading screen.
    if (!force && !hasLocal) {
      final seeded = await _seedCacheFromManifest();
      if (seeded > 0) {
        hasLocal = true;
        final photos = await _cache.allPhotos();
        final folders = await _cache.allFolders();
        // Return the seeded catalog immediately. The live Drive refresh + OCR +
        // thumbnail warm-up is driven by the provider's SEQUENCED seeded
        // catch-up (see _seededCatchUp) — NOT kicked off here — so a fresh
        // install never runs a scrape, OCR, and a 900-image prefetch all at
        // once (that concurrency OOM-crashed the app on first launch).
        return CatalogResult(
          photos: photos,
          folders: folders,
          updatedAt: DateTime.now(),
          fromCache: true,
          // Seed is a snapshot, not an authoritative live diff — don't let the
          // cart-reconcile evict anything based on it.
          authoritative: false,
          seeded: true,
        );
      }
    }

    // Tester 13-Oct: one live Drive walk at a time. The first-launch 90-s
    // timeout only abandons its Future — the walk keeps going — and the
    // catch-up, a pull-to-refresh or a resume re-scan then started a SECOND
    // full walk beside it on the same slow network. A caller arriving while
    // a walk runs now shares that walk (its own progress callbacks are not
    // attached; only the first caller's are).
    final running = _liveWalk;
    if (running != null) return running;
    final walk = _scrapeAndReturn(
      allowFallback: hasLocal,
      onProgress: onProgress,
      onPhotoDiscovered: onPhotoDiscovered,
    );
    _liveWalk = walk;
    walk.then<void>((_) {}, onError: (_) {}).whenComplete(() {
      if (identical(_liveWalk, walk)) _liveWalk = null;
    });
    return walk;
  }

  /// The live Drive walk in progress, if any (see [load]).
  Future<CatalogResult>? _liveWalk;

  /// Once per bundled manifest: correct cached prices with the manifest's
  /// verified ones, before anything is shown. Fixes prices misread earlier
  /// (e.g. from a stale Drive preview) on the very first screen after an update.
  /// 25-Oct: the shop's published price list (prices.json, every photo id →
  /// price) applied to photos still without a price — at most once an hour.
  /// Returns how many photos got a price. Never throws.
  Future<int> applyPublishedPrices(Dio dio, {bool force = false}) async {
    try {
      final last = _prefs.getInt('published_prices_at_v1') ?? 0;
      if (!force && DateTime.now().millisecondsSinceEpoch - last < 3600e3) return 0;
      final res = await dio.get<String>(
          '$kDataBase/app/prices.json?t=${DateTime.now().millisecondsSinceEpoch ~/ 300000}',
          options: Options(responseType: ResponseType.plain, receiveTimeout: const Duration(seconds: 15)));
      final j = jsonDecode(res.data ?? '{}') as Map<String, dynamic>;
      final p = (j['p'] as Map?) ?? const {};
      final prices = <String, int>{
        for (final e in p.entries)
          if (e.value is num && (e.value as num) > 0) '${e.key}': (e.value as num).toInt(),
      };
      final n = await _cache.applyPublishedPrices(prices);
      await _prefs.setInt('published_prices_at_v1', DateTime.now().millisecondsSinceEpoch);
      return n;
    } catch (_) {
      return 0;
    }
  }

  Future<void> _applyBundledPricesOnce() async {
    try {
      final index = await _seedLoader.load();
      final tag = _seedLoader.generatedAt;
      if (index.isEmpty || tag.isEmpty) return;
      if (_prefs.getString(_kVerifiedPricesKey) == tag) return;
      await _cache.applyVerifiedPrices([
        for (final e in index.values)
          if (e.price != null && e.driveVersion != null && e.ocrText.isNotEmpty)
            (
              id: e.id,
              price: e.price!,
              priceText: e.priceText ?? 'Rs ${e.price}/-',
              version: e.driveVersion!,
            ),
      ]);
      await _prefs.setString(_kVerifiedPricesKey, tag);
    } catch (_) {/* non-fatal: prices are still checked against Drive */}
  }

  /// Populate the cache from the bundled `seed_manifest.json` so the catalog is
  /// fully browseable offline the moment the app opens. Returns the number of
  /// photos seeded (0 if the manifest is missing/empty). Additive — never
  /// deletes — so the subsequent live scrape stays authoritative.
  Future<int> _seedCacheFromManifest() async {
    try {
      final index = await _seedLoader.load();
      if (index.isEmpty) return 0;
      final scrapeTs = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final photos = <Photo>[];
      final folders = <String>{};
      for (final e in index.values) {
        photos.add(Photo(
          id: e.id,
          filename: e.filename,
          folder: e.folder,
          designNumber: e.designNumber ?? extractDesignNumber(e.filename),
          // Match the live scrape: don't surface the raw OCR fabric_name (it's
          // noisy). Price + design number are the useful, displayed fields.
          fabricName: null,
          price: e.price,
          priceText: e.priceText,
          ocrText: e.ocrText,
          // A seeded price counts as done; missing prices stay pending so the
          // background OCR runner reads them off the image later.
          ocrState: e.price != null ? OcrState.done : OcrState.pending,
          lastSeen: scrapeTs,
          driveModified: e.firstSeen?.millisecondsSinceEpoch,
          driveVersion: e.driveVersion,
        ));
        if (e.folder.isNotEmpty) {
          final parts = e.folder.split('/');
          for (int i = 1; i <= parts.length; i++) {
            folders.add(parts.sublist(0, i).join('/'));
          }
        }
      }
      if (photos.isEmpty) return 0;
      await _cache.upsertScrape(
        seenPhotos: photos,
        folders: folders,
        scrapeTimestamp: scrapeTs,
        deleteMissing: false,
      );
      return photos.length;
    } catch (_) {
      return 0;
    }
  }

  /// Fast, targeted refresh of ONE top-level [folderName] (e.g. the
  /// "DAILY UPDATE" folder opened from the 9 PM notification). Lists just that
  /// single Drive folder and additively upserts its photos into the cache —
  /// vastly quicker than a full [load], so the folder view reflects the latest
  /// designs the instant it opens instead of waiting for the whole catalog tree
  /// to re-walk.
  ///
  /// Additive only (never deletes), so a flaky/empty read can't wipe the folder
  /// and the cart stays intact; the full background sync that runs right after
  /// handles any removals + cart reconcile authoritatively. Returns true if it
  /// refreshed, false on any lookup/network miss (caller falls back to a full
  /// load).
  Future<bool> refreshSingleFolder(String folderName) async {
    try {
      // 1. Find the folder's Drive ID by listing the catalog root.
      final rootItems = await _scraper.listFolder(kDriveFolderId);
      if (rootItems.isEmpty) return false;
      final target = folderName.trim().toLowerCase();
      String? folderId;
      for (final it in rootItems) {
        if (it.isFolder && it.name.trim().toLowerCase() == target) {
          folderId = it.id;
          break;
        }
      }
      if (folderId == null) return false;

      // 2. List that one folder's images.
      final items = await _scraper.listFolder(folderId);
      final seed = await _seedLoader.load();
      final fp = extractFolderPrice(folderName);
      final scrapeTs = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final photos = <Photo>[];
      for (final it in items) {
        if (it.isFolder || !DriveScraper.isImageName(it.name)) continue;
        photos.add(Photo(
          id: it.id,
          filename: it.name,
          folder: folderName,
          designNumber: extractDesignNumber(it.name),
          fabricName: null,
          price: fp.price,
          priceText: fp.priceText,
          ocrText: '',
          ocrState: fp.price != null ? OcrState.done : OcrState.pending,
          lastSeen: scrapeTs,
          driveModified: _newToOldDate(it.id, it.modified, seed),
        ));
      }
      if (photos.isEmpty) return false; // never wipe on an empty/flaky read

      // 3. Additive upsert — new designs appear, nothing is deleted.
      await _cache.upsertScrape(
        seenPhotos: photos,
        folders: {folderName},
        scrapeTimestamp: scrapeTs,
        deleteMissing: false,
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Drive's Last modified, capped at the date the bundled manifest already
  /// knew the design from — replacing an old photo mustn't make it look new.
  int? _newToOldDate(
      String id, DateTime? modified, Map<String, SeedEntry> seed) {
    final known = seed[id]?.firstSeen;
    if (modified == null) return known?.millisecondsSinceEpoch;
    if (known != null && known.isBefore(modified)) {
      return known.millisecondsSinceEpoch;
    }
    return modified.millisecondsSinceEpoch;
  }

  /// When Drive was last scanned (complete or not), or null if never.
  DateTime? get lastScrapeAt {
    final ms = _prefs.getInt(_kLastScrapeKey) ?? 0;
    return ms == 0 ? null : DateTime.fromMillisecondsSinceEpoch(ms);
  }

  /// Age of the cached catalog (Duration.zero if no cache).
  Duration get cacheAge {
    final lastMs = _prefs.getInt(_kLastScrapeKey) ?? 0;
    if (lastMs == 0) return Duration.zero;
    return Duration(
        milliseconds: DateTime.now().millisecondsSinceEpoch - lastMs);
  }

  Future<CatalogResult> _scrapeAndReturn({
    required bool allowFallback,
    void Function(int folders, int photos)? onProgress,
    void Function(DrivePhoto photo)? onPhotoDiscovered,
  }) async {
    try {
      final now = DateTime.now();
      final scrapeTs = now.millisecondsSinceEpoch ~/ 1000;
      // The bundled seed manifest is no longer used as a backfill — the live
      // Drive scrape is authoritative so deleted/moved photos disappear from
      // the app immediately on refresh.
      final seedIndex = const <String, dynamic>{};
      final seed = await _seedLoader.load();

      // Folder-name price cache — one regex per unique folder.
      final folderPriceCache = <String, ({int? price, String? priceText})>{};
      ({int? price, String? priceText}) folderPriceFor(String folder) =>
          folderPriceCache.putIfAbsent(
              folder, () => extractFolderPrice(folder));

      // Track every photo we see so we can build the final list.
      final discoveredPhotos = <DrivePhoto>[];
      final seenIds = <String>{};

      final walkResult = await _scraper.walk(
        kDriveFolderId,
        onProgress: onProgress,
        onPhotoDiscovered: (dp) {
          discoveredPhotos.add(dp);
          seenIds.add(dp.id);
          onPhotoDiscovered?.call(dp);
        },
      );
      final scrapeComplete = walkResult.complete;

      // Seed-backfill any photos the live scrape missed.
      var seedBackfilled = 0;
      for (final entry in seedIndex.values) {
        if (seenIds.contains(entry.id)) continue;
        final dp = DrivePhoto(
            id: entry.id, name: entry.filename, folder: entry.folder);
        discoveredPhotos.add(dp);
        seenIds.add(dp.id);
        seedBackfilled++;
      }

      // Build Photo list.
      //   - price = folder-name price when present.
      //   - If folder gives a price → ocrState=done (no per-photo OCR needed).
      //   - If folder gives no price → ocrState=pending so the background
      //     price-OCR runner picks the photo up and reads the price off the
      //     fabric image itself. LocalCache.upsertScrape preserves any
      //     previously-computed OCR fields for pending rows, so per-device OCR
      //     results survive future re-scrapes.
      final photos = <Photo>[];
      for (final dp in discoveredPhotos) {
        final fp = folderPriceFor(dp.folder);
        final hasFolderPrice = fp.price != null;
        photos.add(Photo(
          id: dp.id,
          filename: dp.name,
          folder: dp.folder,
          designNumber: extractDesignNumber(dp.name),
          fabricName: null,
          price: fp.price,
          priceText: fp.priceText,
          ocrText: '',
          ocrState: hasFolderPrice ? OcrState.done : OcrState.pending,
          lastSeen: scrapeTs,
          driveModified: _newToOldDate(dp.id, dp.modified, seed),
        ));
      }
      // ignore: avoid_print
      print('[catalog] scrape=${discoveredPhotos.length - seedBackfilled} '
          'backfill=$seedBackfilled total=${photos.length} '
          'folder-priced=${folderPriceCache.values.where((v) => v.price != null).length}');

      // Folder set with every ancestor included
      final folders = <String>{};
      for (final p in photos) {
        if (p.folder.isEmpty) continue;
        final parts = p.folder.split('/');
        for (int i = 1; i <= parts.length; i++) {
          folders.add(parts.sublist(0, i).join('/'));
        }
      }

      await _cache.upsertScrape(
        seenPhotos: photos,
        folders: folders,
        scrapeTimestamp: scrapeTs,
        // Skip the destructive delete-missing-rows step when the scrape was
        // partial (any folder request flaked). Keeps the cached photos
        // visible until a fully-successful scrape produces an authoritative
        // diff. Without this, a flaky Drive listing was nuking real photos.
        deleteMissing: scrapeComplete,
      );
      await _prefs.setInt(_kLastScrapeKey, now.millisecondsSinceEpoch);
      // Only update the "known totals" snapshot when the scrape was complete;
      // a partial walk shouldn't move the goalposts for the loading screen.
      if (scrapeComplete) {
        // The whole Drive tree was walked successfully — trust the cache now.
        await _prefs.setBool(_kScrapeOkKey, true);
        await _prefs.setInt(_kLastTotalFoldersKey, folders.length);
        await _prefs.setInt(_kLastTotalPhotosKey, photos.length);
      }

      // Return the merged cache view (preserves prior OCR results for
      // unchanged photos).
      final merged = await _cache.allPhotos();
      return CatalogResult(
        photos: merged,
        folders: (await _cache.allFolders()),
        updatedAt: now,
        fromCache: false,
        // Only a complete walk gives an authoritative list of what still
        // exists in Drive — required before we evict anything from the cart.
        authoritative: scrapeComplete,
      );
    } catch (e) {
      if (allowFallback) {
        final photos = await _cache.allPhotos();
        final folders = await _cache.allFolders();
        return CatalogResult(
          photos: photos,
          folders: folders,
          updatedAt: DateTime.fromMillisecondsSinceEpoch(
              _prefs.getInt(_kLastScrapeKey) ?? 0),
          fromCache: true,
        );
      }
      throw CatalogServiceException(_friendly(e));
    }
  }

  String _friendly(Object e) {
    final s = e.toString().toLowerCase();
    if (s.contains('socket') || s.contains('failed host lookup')) {
      return 'No internet connection.';
    }
    if (s.contains('403') || s.contains('forbidden')) {
      return 'Catalog folder is not public. Re-share with "Anyone with the link".';
    }
    if (s.contains('404')) {
      return 'Catalog folder not found. Check the folder ID in config.';
    }
    return 'Could not load catalog: $e';
  }
}
