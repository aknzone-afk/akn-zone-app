import 'dart:async';
import 'dart:collection';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config.dart';
import '../models/filter_state.dart';
import '../models/folder.dart';
import '../models/photo.dart';
import '../services/catalog_service.dart';
import '../services/drive_scraper.dart';
import '../services/drive_urls.dart';
import '../services/favorites_service.dart';
import '../services/edit_service.dart';
import '../services/geofence_service.dart';
import '../services/local_cache.dart';
import '../services/photo_freshness.dart';
import '../services/price_check.dart';
import '../services/price_ocr.dart';
import '../services/seed_loader.dart';
import '../services/share_service.dart';
import '../services/picks_service.dart';

/// Initialised once in main.dart via [ProviderScope.overrides].
final sharedPreferencesProvider = Provider<SharedPreferences>((ref) {
  throw UnimplementedError(
      'Override in main() with awaited SharedPreferences instance');
});

final dioProvider = Provider<Dio>((ref) {
  final dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 20),
    receiveTimeout: const Duration(seconds: 30),
    sendTimeout: const Duration(seconds: 20),
    headers: {'User-Agent': 'Mozilla/5.0 (Android) CatalogApp/1.0'},
  ));
  dio.interceptors.add(InterceptorsWrapper(
    onError: (e, handler) async {
      final shouldRetry = e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.receiveTimeout ||
          e.type == DioExceptionType.connectionError ||
          (e.response?.statusCode != null &&
              (e.response!.statusCode! == 429 ||
                  e.response!.statusCode! >= 500));
      final attempt = (e.requestOptions.extra['attempt'] as int?) ?? 0;
      if (shouldRetry && attempt < 2) {
        await Future<void>.delayed(
            Duration(milliseconds: 400 * (1 << attempt)));
        e.requestOptions.extra['attempt'] = attempt + 1;
        try {
          final res = await dio.fetch<dynamic>(e.requestOptions);
          return handler.resolve(res);
        } catch (err) {
          if (err is DioException) return handler.next(err);
          rethrow;
        }
      }
      return handler.next(e);
    },
  ));
  return dio;
});

final localCacheProvider = Provider<LocalCache>((ref) => LocalCache());

final driveScraperProvider = Provider<DriveScraper>((ref) {
  return DriveScraper(dio: ref.watch(dioProvider));
});

final seedLoaderProvider = Provider<SeedLoader>((ref) => SeedLoader());

final catalogServiceProvider = Provider<CatalogService>((ref) {
  return CatalogService(
    scraper: ref.watch(driveScraperProvider),
    cache: ref.watch(localCacheProvider),
    prefs: ref.watch(sharedPreferencesProvider),
    seedLoader: ref.watch(seedLoaderProvider),
  );
});

final favoritesServiceProvider = Provider<FavoritesService>((ref) {
  return FavoritesService(ref.watch(localCacheProvider));
});

final shareServiceProvider = Provider<ShareService>((ref) => ShareService());

final editServiceProvider = Provider<EditService>((ref) => EditService());

final geofenceServiceProvider = Provider<GeofenceService>((ref) {
  return GeofenceService(ref.watch(dioProvider));
});

/// Master switch for the Surat geofence lock. OFF — superseded by the
/// customer OTP login gate (access_control.dart): an approved-customers-only
/// app blocks local competitors far more reliably than IP geolocation, which
/// we saw misplace even a Surat connection. Code kept in case it's ever
/// wanted again.
final bool kGeofenceLockEnabled = false;

/// Resolves to `true` when the customer is allowed into the app, `false` when
/// they should see the geofence lock screen. With [kGeofenceLockEnabled] off
/// this always allows access instantly (no network check, no lock screen).
/// When on: first read kicks off the IP-geo check; subsequent reads in the same
/// 24h window are instant (cached in SharedPreferences).
final geofenceAllowedProvider = FutureProvider<bool>((ref) async {
  if (!kGeofenceLockEnabled) return true;
  final svc = ref.watch(geofenceServiceProvider);
  final prefs = ref.watch(sharedPreferencesProvider);
  // Fail OPEN fast: if the IP-geo check is slow (≥6s), allow access. This keeps
  // the app from ever hanging on the loading screen and guarantees an App
  // Review tester is never stalled or locked out by a sluggish/blocked lookup.
  return svc.isAllowed(prefs).timeout(
        const Duration(seconds: 6),
        onTimeout: () => true,
      );
});

/// IDs of photos that have a saved markup edit on disk → a monotonic version
/// counter that increments every time that photo is re-saved. Cart tiles use
/// the version to bust the Flutter image cache so the freshly-edited PNG
/// shows up immediately after the user taps SAVE.
class EditsNotifier extends StateNotifier<Map<String, int>> {
  EditsNotifier(this._svc) : super(const {}) {
    _hydrate();
  }
  final EditService _svc;

  Future<void> _hydrate() async {
    final ids = await _svc.listAll();
    state = {for (final id in ids) id: 1};
  }

  bool isEdited(String id) => state.containsKey(id);
  int versionFor(String id) => state[id] ?? 0;

  Future<void> markSaved(String id) async {
    final next = (state[id] ?? 0) + 1;
    state = {...state, id: next};
  }

  Future<void> markRemoved(String id) async {
    await _svc.remove(id);
    final next = {...state}..remove(id);
    state = next;
  }

  /// Its baked edit was dropped because the photo was replaced on Drive.
  void markStale(String id) {
    if (!state.containsKey(id)) return;
    state = {...state}..remove(id);
  }
}

final editsProvider =
    StateNotifierProvider<EditsNotifier, Map<String, int>>((ref) {
  return EditsNotifier(ref.watch(editServiceProvider));
});

/// Phases the first-install loading screen passes through.
enum ScrapePhase { idle, scanning, preparing, pricing }

/// Streaming scrape progress for the loading collage.
class ScrapeProgress {
  final int foldersDone;
  final int photosFound;
  final ScrapePhase phase;
  final int coversReady;
  final int coversTotal;
  final int ocrReady;
  final int ocrTotal;
  const ScrapeProgress({
    required this.foldersDone,
    required this.photosFound,
    required this.phase,
    this.coversReady = 0,
    this.coversTotal = 0,
    this.ocrReady = 0,
    this.ocrTotal = 0,
  });
  static const empty = ScrapeProgress(
    foldersDone: 0,
    photosFound: 0,
    phase: ScrapePhase.idle,
  );

  ScrapeProgress copyWith({
    int? foldersDone,
    int? photosFound,
    ScrapePhase? phase,
    int? coversReady,
    int? coversTotal,
    int? ocrReady,
    int? ocrTotal,
  }) {
    return ScrapeProgress(
      foldersDone: foldersDone ?? this.foldersDone,
      photosFound: photosFound ?? this.photosFound,
      phase: phase ?? this.phase,
      coversReady: coversReady ?? this.coversReady,
      coversTotal: coversTotal ?? this.coversTotal,
      ocrReady: ocrReady ?? this.ocrReady,
      ocrTotal: ocrTotal ?? this.ocrTotal,
    );
  }
}

final scrapeProgressProvider =
    StateProvider<ScrapeProgress>((_) => ScrapeProgress.empty);

/// Photos discovered *during the current scrape*, capped to the most recent
/// [_maxDiscovered]. Drives the loading-screen collage.
const int kMaxDiscoveredForCollage = 36;

final discoveredPhotosProvider =
    StateProvider<List<DrivePhoto>>((_) => const []);

/// What the last successful scrape found, so the loading screen can show a %.
final lastKnownTotalsProvider = Provider<({int folders, int photos})>((ref) {
  final svc = ref.watch(catalogServiceProvider);
  return (folders: svc.lastKnownFolderCount, photos: svc.lastKnownPhotoCount);
});

/// Async load of the catalog.
///
/// First install (no cache): does a foreground scrape that drives the loading
/// screen with percentage. After that, the loading screen never appears again
/// — subsequent opens serve the SQLite cache instantly and (when the cache is
/// older than [kCatalogRefreshInterval]) trigger a *silent* background scrape
/// that updates the cache without blocking the UI.
final FutureProvider<CatalogResult> catalogProvider =
    FutureProvider<CatalogResult>((ref) async {
  ref.read(scrapeProgressProvider.notifier).state = ScrapeProgress.empty;
  ref.read(discoveredPhotosProvider.notifier).state = const [];

  final svc = ref.watch(catalogServiceProvider);
  ref.read(scrapeProgressProvider.notifier).state =
      ScrapeProgress.empty.copyWith(phase: ScrapePhase.scanning);

  var result = await svc.load(
    onProgress: (folders, photos) {
      final cur = ref.read(scrapeProgressProvider);
      ref.read(scrapeProgressProvider.notifier).state = cur.copyWith(
        foldersDone: folders,
        photosFound: photos,
      );
    },
    onPhotoDiscovered: (photo) {
      final notifier = ref.read(discoveredPhotosProvider.notifier);
      final current = notifier.state;
      if (current.length >= kMaxDiscoveredForCollage) {
        notifier.state = [...current.skip(1), photo];
      } else {
        notifier.state = [...current, photo];
      }
    },
  );

  // FIRST LAUNCH (bundled catalog): show the branded loading screen BRIEFLY —
  // powered by the bundled data + folder covers, so it finishes in ~1-2s every
  // time, even offline — then reveal the COMPLETE app. This restores the "it
  // loads first, then opens" feel WITHOUT the empty/loading screen that Apple
  // rejected (the load now always completes fast and shows a full catalog).
  // After the reveal, catch up to live Drive + remaining prices + all
  // thumbnails in a SINGLE SEQUENCED background pass (never concurrently — that
  // spiked memory and crashed the app on a fresh install).
  if (result.seeded) {
    // FIRST LAUNCH — full "wait for everything, then open a complete & accurate
    // catalog" load (the original first-run behaviour). Behind the loading
    // screen we: (1) scan the LIVE Drive, (2) warm the folder covers, (3) read
    // EVERY remaining price — and only THEN reveal the finished catalog. So the
    // user never sees stale folders vanish or prices fill in afterwards; they
    // wait a little and get the complete, current catalog.
    //
    // The bundled seed is used ONLY as a fallback when Drive can't be reached
    // (e.g. a review device on a blocked network), so a full catalog still
    // appears and we never show the empty screen that caused the App Store
    // rejection.
    ref.read(scrapeProgressProvider.notifier).state =
        ScrapeProgress.empty.copyWith(phase: ScrapePhase.scanning);
    ref.read(discoveredPhotosProvider.notifier).state = const [];

    CatalogResult shown;
    bool liveScraped = false;
    try {
      shown = await svc
          .load(
            force: true,
            onProgress: (folders, photos) {
              final cur = ref.read(scrapeProgressProvider);
              ref.read(scrapeProgressProvider.notifier).state =
                  cur.copyWith(foldersDone: folders, photosFound: photos);
            },
            onPhotoDiscovered: (photo) {
              final n = ref.read(discoveredPhotosProvider.notifier);
              final cur = n.state;
              n.state = cur.length >= kMaxDiscoveredForCollage
                  ? [...cur.skip(1), photo]
                  : [...cur, photo];
            },
          )
          // Generous ceiling so the full load can finish, but never hangs.
          .timeout(const Duration(seconds: 90));
      // Only a complete walk counts as live; after a partial one the catch-up
      // keeps retrying Drive.
      liveScraped = shown.authoritative;
      if (shown.photos.isEmpty) shown = result; // empty scrape → keep the seed
    } catch (_) {
      shown = result; // unreachable / too slow → bundled seed fallback
    }

    // Warm folder covers so the grid opens fully painted (preparing phase).
    await _prefetchTopLevelCovers(ref, shown)
        .timeout(const Duration(seconds: 12), onTimeout: () {});

    if (liveScraped) {
      // Read EVERY remaining price before revealing — full accuracy at open.
      // (Designs whose folder name or the bundled seed already gave a price are
      // skipped, so this only reads the ones genuinely missing one.)
      await _runPriceOcr(ref)
          .timeout(const Duration(seconds: 90), onTimeout: () => 0);
      // Re-read the cache so the revealed catalog includes those prices.
      shown = await _reloadFromCache(ref, shown);
    }

    ref.read(scrapeProgressProvider.notifier).state =
        ref.read(scrapeProgressProvider).copyWith(phase: ScrapePhase.idle);
    ref.read(discoveredPhotosProvider.notifier).state = const [];

    // Bundled-seed prices may come from files replaced since: verify them
    // against Drive, then warm every thumbnail. Runs under the catch-up guard
    // so its catalog refreshes can't start a Drive re-scan alongside it. If
    // Drive was unreachable, this also keeps trying to reconcile to live.
    // ignore: discarded_futures
    _seededCatchUp(ref, didLiveScrape: liveScraped);

    // Drop cart entries for designs removed from Drive — only when what we're
    // showing is the authoritative live scrape.
    if (shown.authoritative) {
      final validIds = {for (final p in shown.photos) p.id};
      // ignore: discarded_futures
      ref.read(favoritesProvider.notifier).reconcile(validIds);
    }
    return shown;
  }

  // After scrape completes, prefetch the folder covers so the home grid
  // renders with photos painted.
  if (!result.fromCache) {
    await _prefetchTopLevelCovers(ref, result);
    // Run price OCR on photos whose folder name didn't encode a price. Blocks
    // the loading screen so prices are visible by the time the catalog opens.
    await _runPriceOcr(ref);
    ref.read(scrapeProgressProvider.notifier).state =
        ref.read(scrapeProgressProvider).copyWith(phase: ScrapePhase.idle);
    // Re-read SQLite so the photos list reflects the OCR-extracted prices.
    // (Not by invalidating: that would cancel this build and, while Drive
    // scans stay incomplete, start another scan — endlessly.)
    result = await _reloadFromCache(ref, result);
    // Verify prices against the current Drive files, then warm every
    // thumbnail in the background. Doesn't block the loading screen.
    // ignore: discarded_futures
    _freshnessPass(ref);
  }

  // Always trigger a silent background refresh on cold start when we served
  // from cache, so new photos / folders that appeared in Drive since the
  // previous session show up automatically. UI keeps the cached view; the
  // refresh updates SQLite, and the home screen reads fresh rows on the next
  // user-triggered invalidation.
  // The `!_seedCatchUpActive` guard stops this concurrent work from piling on
  // top of the sequenced seeded catch-up (which invalidates this provider as it
  // progresses, which would otherwise re-fire all three of these at once).
  if (result.fromCache && !_seedCatchUpActive) {
    // ignore: discarded_futures
    _silentForegroundResync(ref);
    // Catch photos replaced on Drive, read any missing prices, then top up
    // the thumbnail cache — in that order, never overlapping.
    // ignore: discarded_futures
    _freshnessPass(ref);
  }

  // Keep the cart honest: when the photo list is authoritative (a complete
  // scrape or the full cache), drop any cart entry whose design was deleted
  // from Drive — along with its orphaned saved markup.
  if (result.authoritative) {
    final validIds = {for (final p in result.photos) p.id};
    // ignore: discarded_futures
    ref.read(favoritesProvider.notifier).reconcile(validIds);
  }

  return result;
});

/// [base] with its photos and folders re-read from SQLite.
Future<CatalogResult> _reloadFromCache(Ref ref, CatalogResult base) async {
  final cache = ref.read(localCacheProvider);
  return CatalogResult(
    photos: await cache.allPhotos(),
    folders: await cache.allFolders(),
    updatedAt: base.updatedAt,
    fromCache: base.fromCache,
    authoritative: base.authoritative,
    seeded: base.seeded,
  );
}

/// The OCR run in progress, if any. Runs are serialized so two callers never
/// download and read the same pending photos twice.
Future<int>? _ocrRun;

/// Walks every photo whose `ocr_state='pending'` in the local cache, downloads
/// its current image from Drive, runs ML Kit text recognition, and persists the
/// recognized price back to SQLite. Updates [scrapeProgressProvider] so the
/// loading screen can show progress.
Future<int> _runPriceOcr(Ref ref, {bool silent = false}) async {
  while (_ocrRun != null) {
    try {
      await _ocrRun;
    } catch (_) {}
  }
  final run = _runPriceOcrOnce(ref, silent: silent);
  _ocrRun = run;
  try {
    return await run;
  } finally {
    if (identical(_ocrRun, run)) _ocrRun = null;
  }
}

Future<int> _runPriceOcrOnce(Ref ref, {required bool silent}) async {
  final cache = ref.read(localCacheProvider);
  final pending = await cache.photosPendingOcr(limit: 1 << 30);
  if (pending.isEmpty) return 0;

  final notifier = ref.read(scrapeProgressProvider.notifier);
  if (!silent) {
    notifier.state = notifier.state.copyWith(
      phase: ScrapePhase.pricing,
      ocrReady: 0,
      ocrTotal: pending.length,
    );
  }

  final ocr = PriceOcr(dio: ref.read(dioProvider));
  var okCount = 0;
  var lastRefresh = DateTime.now();
  try {
    var done = 0;
    final queue = List<Photo>.from(pending);
    Future<void> worker() async {
      while (queue.isNotEmpty) {
        final photo = queue.removeAt(0);
        try {
          // The viewer may have read it meanwhile; don't download it twice.
          final r = await cache.isPending(photo.id)
              ? await ocr.recognize(photo.id)
              : null;
          if (r != null && r.ok) {
            // Prefer verified seed over ML Kit when versions match.
            final s = await _verifiedSeedPrice(
                ref.container, photo.id, r.version ?? '');
            await cache.saveOcr(
              photoId: photo.id,
              fabricName: null,
              price: s?.price ?? r.price,
              priceText: s?.priceText ?? r.priceText,
              ocrText: s?.ocrText ?? r.text,
              state: OcrState.done,
              driveVersion: r.version,
            );
            okCount++;
            // Show new prices as they come in rather than after the whole
            // batch (the blocking first-launch run is revealed at the end).
            if (silent &&
                DateTime.now().difference(lastRefresh) >
                    const Duration(seconds: 2)) {
              lastRefresh = DateTime.now();
              ref.container.invalidate(catalogProvider);
            }
          }
          // !r.ok → the image couldn't be downloaded/processed (usually a
          // network drop). Leave ocr_state='pending' so the photo is retried
          // automatically on the next app open until it succeeds.
        } catch (_) {
          // saveOcr or an unexpected error — also leave it pending to retry.
        }
        done++;
        if (!silent) {
          notifier.state = notifier.state.copyWith(ocrReady: done);
        }
      }
    }

    await Future.wait(
      List.generate(kOcrConcurrency, (_) => worker()),
    );
  } finally {
    ocr.close();
  }
  return okCount;
}

/// A check round confirms every photo's price against the file on Drive. One
/// runs on each cold start, on pull-to-refresh, and when the app comes back
/// after [_kCheckRoundValidity]; the viewer also checks each photo it opens.
const _kCheckRoundValidity = Duration(minutes: 5);
const _kInlineRereads = 20;
DateTime? _lastCheckRound;
bool _checkRoundRunning = false;

/// Photos on screen, checked first while a round is running.
final List<String> _priorityChecks = [];

/// Checks [photoIds] (what the customer is looking at) before the rest of the
/// running round, so their prices appear within a moment of opening.
void prioritizePriceCheck(Iterable<String> photoIds) {
  _priorityChecks
    ..clear()
    ..addAll(photoIds);
}

/// Which photos' prices are confirmed current this session; price labels
/// hide anything unconfirmed (see [priceDisplayFor]).
final priceCheckProvider =
    StateNotifierProvider<PriceCheckNotifier, PriceCheckState>(
        (ref) => PriceCheckNotifier());

/// Compares every photo's stored Drive version with the live one (a HEAD
/// request each — no image download), photos on screen first. A replaced
/// photo gets its old pictures dropped and its price re-read straight away
/// (beyond the first few, only if on screen; the rest by the OCR step that
/// follows). Returns how many photos changed.
Future<int> _verifyDriveVersions(Ref ref, {bool force = false}) async {
  final now = DateTime.now();
  final last = _lastCheckRound;
  if (_checkRoundRunning) return 0;
  if (!force && last != null && now.difference(last) < _kCheckRoundValidity) {
    return 0;
  }
  final cache = ref.read(localCacheProvider);
  final dio = ref.read(dioProvider);
  final photos = await cache.allPhotos();
  if (photos.isEmpty) return 0;

  _checkRoundRunning = true;
  final check = ref.read(priceCheckProvider.notifier);
  check.startRound();
  final byId = {for (final p in photos) p.id: p};
  final remaining = LinkedHashSet<String>.of(byId.keys);
  final queuedForOcr = <String>{};
  ({String id, bool onScreen})? next() {
    while (_priorityChecks.isNotEmpty) {
      final id = _priorityChecks.removeAt(0);
      if (remaining.remove(id)) return (id: id, onScreen: true);
      if (queuedForOcr.contains(id)) {
        queuedForOcr.remove(id);
        return (id: id, onScreen: true);
      }
    }
    if (remaining.isEmpty) return null;
    final id = remaining.first;
    remaining.remove(id);
    return (id: id, onScreen: false);
  }

  final live = <String, String>{};
  var changed = 0;
  var failures = 0;
  var successes = 0;
  bool trustedByFailure = false;
  final evictBatch = <String>{};
  Future<void> worker() async {
    for (var item = next(); item != null; item = next()) {
      final p = byId[item.id]!;
      final r = await fetchDriveVersion(dio, p.id);
      if (!r.reached) {
        if (++failures >= 3 && successes == 0) {
          check.trust();
          trustedByFailure = true;
        }
        continue;
      }
      successes++;
      if (trustedByFailure) {
        check.distrust();
        trustedByFailure = false;
      }
      final v = r.version;
      if (v == null) continue;
      live[p.id] = v;
      check.record(p.id, v);
      if (v == p.driveVersion) {
        if (item.onScreen && p.ocrState == OcrState.pending && !p.priceFromFolder) {
          await _applyNewVersion(ref, p, v, readNow: true, evictBatch: evictBatch);
        }
        continue;
      }
      changed++;
      final readNow = item.onScreen || changed <= _kInlineRereads;
      if (!readNow) queuedForOcr.add(p.id);
      await _applyNewVersion(ref, p, v,
          readNow: readNow, evictBatch: evictBatch);
    }
  }

  try {
    await Future.wait(List.generate(16, (_) => worker()));
    if (evictBatch.isNotEmpty) await evictPhotoImages(evictBatch);
    await forgetOutdatedPictures(ref.container, const {}, live);
  } finally {
    check.trust();
    _checkRoundRunning = false;
    _lastCheckRound = failures <= photos.length ~/ 20
        ? now
        : now.subtract(_kCheckRoundValidity - const Duration(minutes: 3));
  }
  return changed;
}

/// [p]'s file on Drive is now at version [live]: drop pictures of the old
/// file and queue its price for re-reading — or, with [readNow], read it
/// immediately. [evictBatch] collects ids for a single batched eviction.
Future<void> _applyNewVersion(Ref ref, Photo p, String live,
    {required bool readNow, Set<String>? evictBatch}) async {
  final cache = ref.read(localCacheProvider);
  final outdated =
      p.driveVersion != null || await hasOutdatedCachedImage(p.id, live);
  if (outdated) {
    if (evictBatch != null) {
      evictBatch.add(p.id);
      // Still drop edits immediately.
      await forgetOutdatedPictures(ref.container, {p.id}, {p.id: live},
          skipImageEvict: true);
    } else {
      await forgetOutdatedPictures(ref.container, {p.id}, {p.id: live});
    }
  }
  if (p.priceFromFolder) {
    await cache.saveDriveVersions({p.id: live});
    return;
  }
  // Check if the bundled seed has a verified price for this exact version.
  final seed = await _verifiedSeedPrice(ref.container, p.id, live);
  if (seed != null) {
    await cache.saveOcr(
      photoId: p.id,
      fabricName: null,
      price: seed.price,
      priceText: seed.priceText,
      ocrText: seed.ocrText,
      state: OcrState.done,
      driveVersion: live,
    );
    ref.container.invalidate(catalogProvider);
    return;
  }
  await cache.saveDriveVersions({p.id: live}, needsReread: {p.id});
  if (!readNow) return;
  final ocr = PriceOcr(dio: ref.read(dioProvider));
  try {
    final r = await ocr.recognize(p.id);
    if (r.ok) {
      // Prefer verified seed over ML Kit when versions match.
      final s = await _verifiedSeedPrice(ref.container, p.id, r.version ?? live);
      await cache.saveOcr(
        photoId: p.id,
        fabricName: null,
        price: s?.price ?? r.price,
        priceText: s?.priceText ?? r.priceText,
        ocrText: s?.ocrText ?? r.text,
        state: OcrState.done,
        driveVersion: r.version ?? live,
      );
      ref.container.invalidate(catalogProvider);
    }
  } catch (_) {/* stays pending; the OCR step retries it */} finally {
    ocr.close();
  }
}

/// Returns the seed entry if it has a verified price for exactly [version].
Future<SeedEntry?> _verifiedSeedPrice(
    ProviderContainer c, String id, String version) async {
  final s = (await c.read(seedLoaderProvider).load())[id];
  if (s == null || s.price == null || s.ocrText.isEmpty) return null;
  return s.driveVersion == version ? s : null;
}

/// Drops every on-device copy of outdated pictures: cached images, and cart
/// edits drawn on an older file (their strokes are kept, so re-opening the
/// editor redraws them on the new photo). [live] holds current versions.
Future<void> forgetOutdatedPictures(ProviderContainer container,
    Set<String> outdated, Map<String, String> live,
    {bool skipImageEvict = false}) async {
  final edits = container.read(editServiceProvider);
  final dio = container.read(dioProvider);
  final stale = <String>{};
  for (final id in await edits.listAll()) {
    final v = live[id];
    if (v == null) continue;
    final drawnOn = await edits.readVersion(id);
    final bool isStale;
    if (drawnOn != null) {
      isStale = drawnOn != v;
    } else if (outdated.contains(id)) {
      isStale = true;
    } else {
      // Saved before versions were recorded: check it against the file.
      final check = await _legacyEditIsCurrent(edits, dio, id);
      if (check == null) continue; // couldn't tell now; retried next pass
      if (check.current) {
        await edits.saveVersion(id, check.version ?? v);
        continue;
      }
      isStale = true;
    }
    if (isStale && await edits.dropRendered(id)) stale.add(id);
  }
  final notifier = container.read(editsProvider.notifier);
  for (final id in stale) {
    notifier.markStale(id);
  }
  if (!skipImageEvict) await evictPhotoImages(outdated);
}

/// Whether an unversioned edit was drawn on the current Drive file: its saved
/// base is the exact original bytes it was drawn on, and Drive returns the
/// same bytes at [kDetailImageWidth] until the file is replaced. Null if the
/// current file couldn't be fetched.
Future<({bool current, String? version})?> _legacyEditIsCurrent(
    EditService edits, Dio dio, String id) async {
  final base = await edits.readBase(id);
  // Very old edits kept no clean base; nothing to compare, so keep them.
  if (base == null) return (current: true, version: null);
  try {
    final res = await dio.get<List<int>>(
      DriveUrls.thumbnail(id, width: kDetailImageWidth),
      options: Options(responseType: ResponseType.bytes),
    );
    final now = res.data ?? const <int>[];
    final version = normalizeEtag(res.headers.value('etag'));
    if (listEquals(base, now)) return (current: true, version: version);
    // A base that is itself a baked PNG edit can't be compared to the JPEG
    // original; keep it rather than wipe a customer's marks on a guess.
    final basePng = base.length > 3 && base[0] == 0x89 && base[1] == 0x50;
    final nowJpeg = now.length > 2 && now[0] == 0xFF && now[1] == 0xD8;
    if (basePng && nowJpeg) return (current: true, version: version);
    return (current: false, version: version);
  } catch (_) {
    return null;
  }
}

/// The background freshness pass in progress, if any. A request arriving
/// mid-pass (e.g. a scrape just added photos) makes the pass loop once more
/// instead of starting a second, overlapping one.
Future<void>? _freshnessRun;
bool _freshnessRerun = false;
bool _freshnessRerunForced = false;

/// Verify Drive versions → read pending prices → warm thumbnails, strictly in
/// sequence so the network and ML Kit work never pile up at once.
Future<void> _freshnessPass(Ref ref, {bool forceVersionCheck = false}) {
  final inFlight = _freshnessRun;
  if (inFlight != null) {
    _freshnessRerun = true;
    if (forceVersionCheck) _freshnessRerunForced = true;
    return inFlight;
  }
  final run = () async {
    var force = forceVersionCheck;
    try {
      while (true) {
        _freshnessRerun = false;
        _freshnessRerunForced = false;
        // The price check starts at once (HEAD requests only, light enough to
        // run beside a Drive re-scan); reading prices waits for both, so
        // photos the re-scan adds are priced in this same pass.
        try {
          final changed = await _verifyDriveVersions(ref, force: force);
          if (changed > 0) ref.container.invalidate(catalogProvider);
        } catch (_) {/* silent */}
        final resync = _resyncRun;
        if (resync != null) await resync;
        try {
          final read = await _runPriceOcr(ref, silent: true);
          if (read > 0) ref.container.invalidate(catalogProvider);
        } catch (_) {/* silent */}
        try {
          final photos = await ref.read(localCacheProvider).allPhotos();
          await _prefetchAllThumbnails(ref, photos.map((p) => p.id));
        } catch (_) {/* silent */}
        if (!_freshnessRerun) break;
        force = _freshnessRerunForced;
      }
    } finally {
      _freshnessRun = null;
    }
  }();
  _freshnessRun = run;
  return run;
}

/// App-resume hook: the same throttled re-scan and replaced-photo check a
/// cold start runs.
final catalogResumeCheckProvider = Provider<void Function()>((ref) {
  return () {
    if (_seedCatchUpActive || !ref.read(catalogProvider).hasValue) return;
    // ignore: discarded_futures
    _silentForegroundResync(ref);
    // ignore: discarded_futures
    _freshnessPass(ref);
  };
});

/// Pull-to-refresh hook: re-check every photo against Drive right now,
/// ignoring the hourly throttle.
final photoFreshnessProvider = Provider<Future<void> Function()>((ref) {
  return () => _freshnessPass(ref, forceVersionCheck: true);
});

/// Guard so we only kick off one background warm-cache pass per app session.
bool _allThumbsPrefetchInFlight = false;

/// Warms `cached_network_image`'s shared disk cache with EVERY photo's
/// thumbnail AND detail-size image so the user never sees a loading shimmer.
/// Thumbnails run first (fast, high priority — needed for grid view). Detail
/// images follow at lower concurrency (heavier per-file) so swiping through
/// the full-screen viewer is instant too.
Future<void> _prefetchAllThumbnails(Ref ref, Iterable<String> photoIds) async {
  if (_allThumbsPrefetchInFlight) return;
  _allThumbsPrefetchInFlight = true;
  try {
    final manager = photoCacheManager;
    final ids = photoIds.toList(growable: false);
    if (ids.isEmpty) return;

    Future<void> warmList(List<String> urls, int concurrency) async {
      final queue = List<String>.from(urls);
      Future<void> worker() async {
        // Stops early when new work (e.g. photos to price) is waiting; what's
        // already cached is skipped on the next run, so nothing is lost.
        while (queue.isNotEmpty && !_freshnessRerun) {
          final url = queue.removeAt(0);
          try {
            // Cheap check: skip the network entirely if the file is already
            // on disk. flutter_cache_manager's downloadFile is idempotent but
            // does a HEAD request to verify freshness, which we'd rather
            // avoid for a 1k-photo catalog.
            final cached = await manager.getFileFromCache(url);
            if (cached != null) continue;
            await manager
                .downloadFile(url)
                .timeout(const Duration(seconds: 60));
          } catch (_) {/* missing thumb is non-fatal */}
        }
      }

      await Future.wait(List.generate(concurrency, (_) => worker()));
    }

    // 1. Grid thumbnails first — small, fast, makes folder view instant.
    final thumbs = ids
        .map((id) => DriveUrls.thumbnail(id, width: kThumbnailWidth))
        .toList(growable: false);
    await warmList(thumbs, 16);

    // 2. Detail-size images — heavier per-file, lower concurrency so we
    // don't saturate the pipe and starve UI image loads the user actually
    // triggers via taps. Once this completes the full-screen viewer needs
    // zero network for any photo in the catalog.
    final details = ids
        .map((id) => DriveUrls.thumbnail(id, width: kDetailImageWidth))
        .toList(growable: false);
    await warmList(details, 6);
  } finally {
    _allThumbsPrefetchInFlight = false;
  }
}

/// Warm `cached_network_image`'s shared disk cache with every top-level folder
/// cover. The Future resolves only when all covers are downloaded (or have
/// failed), so the home grid never appears with empty tiles.
Future<void> _prefetchTopLevelCovers(Ref ref, CatalogResult result) async {
  // Build the cover list deterministically: first photo per top-level folder.
  final covers = <String>{};
  for (final p in result.photos) {
    final top = p.topFolder;
    if (covers.length < 60 && !covers.any((existing) => false)) {
      // we'll just key by topFolder via a map
    }
  }
  // Use a map for deterministic order.
  final byTop = <String, String>{}; // top-folder -> first photo id
  for (final p in result.photos) {
    byTop.putIfAbsent(p.topFolder, () => p.id);
  }
  final urls = byTop.values
      .map((id) => DriveUrls.thumbnail(id, width: kThumbnailWidth))
      .toList();
  if (urls.isEmpty) return;

  final notifier = ref.read(scrapeProgressProvider.notifier);
  notifier.state = notifier.state.copyWith(
    phase: ScrapePhase.preparing,
    coversReady: 0,
    coversTotal: urls.length,
  );

  final manager = photoCacheManager;
  var done = 0;
  const concurrency = 6;
  final queue = List<String>.from(urls);
  Future<void> worker() async {
    while (queue.isNotEmpty) {
      final url = queue.removeAt(0);
      try {
        await manager.downloadFile(url);
      } catch (_) {/* missing thumb is non-fatal */}
      done++;
      notifier.state = notifier.state.copyWith(coversReady: done);
    }
  }

  await Future.wait(List.generate(concurrency, (_) => worker()));
}

/// Strip everything that isn't a letter or digit, then lowercase. Makes
/// "T-56", "T 56", "T_56" and "t56" all match the same query "T56".
String _alnumOnly(String s) =>
    s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

/// True while the first-launch seeded catch-up is running, so the normal
/// concurrent cache-path background work doesn't pile on top of it.
bool _seedCatchUpActive = false;

/// First-launch catch-up after the bundled seed is shown. Does the heavy work
/// SEQUENTIALLY — refresh from Drive, THEN read prices, THEN warm thumbnails —
/// so a fresh install never runs a scrape + OCR + ~900-image prefetch all at
/// once (that concurrency spiked memory and iOS killed the app right after the
/// folders appeared). The catalog is already on screen the whole time.
Future<void> _seededCatchUp(Ref ref, {bool didLiveScrape = false}) async {
  if (_seedCatchUpActive) return;
  _seedCatchUpActive = true;
  try {
    CatalogResult fresh;
    if (didLiveScrape) {
      // The live scrape already ran behind the loading screen, so the cache is
      // already current.
      final cache = ref.read(localCacheProvider);
      fresh = CatalogResult(
        photos: await cache.allPhotos(),
        folders: await cache.allFolders(),
        updatedAt: DateTime.now(),
        fromCache: true,
      );
    } else {
      // We showed the bundled seed (Drive was slow/unreachable). Start the
      // version check NOW (HEAD requests are light) so prices hide immediately,
      // then run the full walk alongside it.
      final walk = ref.read(catalogServiceProvider).load(force: true);
      final gate = walk.then<void>((_) {}, onError: (_) {});
      _resyncRun = gate;
      gate.whenComplete(() {
        if (identical(_resyncRun, gate)) _resyncRun = null;
      });
      final pass = _freshnessPass(ref, forceVersionCheck: true);
      try {
        fresh = await walk;
      } catch (_) {
        // Still offline — let the pass finish with what it has.
        await pass;
        ref.container.invalidate(catalogProvider);
        return;
      }
      ref.container.invalidate(catalogProvider);
      await pass;
      return;
    }
    // AFTER the scrape (never overlapping — that storm crashed a fresh
    // install): verify the bundled prices against the current Drive files,
    // read every price still missing, then warm thumbnails last.
    if (fresh.photos.isNotEmpty) {
      await _freshnessPass(ref, forceVersionCheck: true);
    }
  } catch (_) {/* silent */} finally {
    _seedCatchUpActive = false;
  }
}

/// The silent Drive re-scan in progress, if any.
Future<void>? _resyncRun;
DateTime? _lastResyncAttempt;

/// Re-scans Drive in the background at most once per [kCatalogRefreshInterval]
/// (pull-to-refresh scans on demand). Without the throttle, the catalog
/// refresh at the end of each scan started the next one, back to back.
Future<void> _silentForegroundResync(Ref ref) {
  final running = _resyncRun;
  if (running != null) return running;
  final svc = ref.read(catalogServiceProvider);
  final now = DateTime.now();
  final lastScan = svc.lastScrapeAt;
  final lastAttempt = _lastResyncAttempt;
  if ((lastScan != null &&
          now.difference(lastScan) < kCatalogRefreshInterval) ||
      (lastAttempt != null &&
          now.difference(lastAttempt) < kCatalogRefreshInterval)) {
    return Future.value();
  }
  _lastResyncAttempt = now;
  final run = () async {
    try {
      await svc.load(force: true);
      // Re-read SQLite so the UI surfaces any new photos/folders the scrape
      // just discovered. AsyncValue keeps its value during the reload so the
      // home grid doesn't flash to a loading state.
      ref.container.invalidate(catalogProvider);
    } catch (_) {/* silent */} finally {
      _resyncRun = null;
    }
  }();
  _resyncRun = run;
  return run;
}

/// Flat photo list.
final photosProvider = Provider<List<Photo>>((ref) {
  return ref.watch(catalogProvider).maybeWhen(
        data: (d) => d.photos,
        orElse: () => const <Photo>[],
      );
});

/// Random seed for folder cover ("key") photos. Re-randomised on every app
/// open — cold launch (this initial value) and each time the app returns to
/// the foreground (bumped from CatalogApp's lifecycle observer). So each folder
/// tile shows a DIFFERENT photo from inside that folder every time the customer
/// opens the app, instead of always the same first photo.
final coverSeedProvider =
    StateProvider<int>((ref) => Random().nextInt(0x7fffffff));

/// Picks up to [count] DISTINCT photo ids per group — the first is the cover,
/// the rest peek out behind it as the folder tile's photo stack. Seeded RNG so
/// the picks are stable within a session (no flicker on rebuild) and rotate
/// each app open when the seed changes.
Map<String, List<String>> _pickPreviewStack(
    Map<String, List<String>> byKey, int seed, int count) {
  final out = <String, List<String>>{};
  byKey.forEach((key, ids) {
    final rng = Random(seed ^ key.hashCode);
    final pool = List<String>.from(ids);
    final picked = <String>[];
    while (picked.length < count && pool.isNotEmpty) {
      picked.add(pool.removeAt(rng.nextInt(pool.length)));
    }
    out[key] = picked;
  });
  return out;
}

/// Top-level folders with photo counts (transitive) and cover thumbs.
/// Used by the Home screen.
final topLevelFoldersProvider = Provider<List<CatalogFolder>>((ref) {
  final photos = ref.watch(photosProvider);
  final seed = ref.watch(coverSeedProvider);
  final counts = <String, int>{};
  final byTop = <String, List<String>>{};
  for (final p in photos) {
    final top = p.topFolder;
    counts[top] = (counts[top] ?? 0) + 1;
    (byTop[top] ??= <String>[]).add(p.id);
  }
  final stacks = _pickPreviewStack(byTop, seed, 4);
  final out = counts.entries.map((e) {
    final stack = stacks[e.key] ?? const <String>[];
    return CatalogFolder(
      path: e.key,
      photoCount: e.value,
      coverThumbPath: stack.isEmpty ? null : stack.first,
      previewThumbPaths: stack.length > 1 ? stack.sublist(1) : const <String>[],
    );
  }).toList()
    ..sort((a, b) =>
        a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()));
  out.sort((a, b) {
    if (a.path.isEmpty && b.path.isNotEmpty) return 1;
    if (b.path.isEmpty && a.path.isNotEmpty) return -1;
    return 0;
  });
  return out;
});

/// Direct children of [parentPath] only — non-recursive.
/// `parentPath = ""` for the catalog root.
/// Returns `(sub-folders shown as tiles, photos directly in this folder)`.
final folderContentsProvider = Provider.family<
    ({List<CatalogFolder> subFolders, List<Photo> directPhotos}),
    String>((ref, parentPath) {
  final photos = ref.watch(photosProvider);
  final seed = ref.watch(coverSeedProvider);

  // 1. Direct photos: photos whose folder == parentPath exactly.
  final direct = <Photo>[];
  // 2. Sub-folder discovery: for each photo whose folder starts with
  //    "$parentPath/" (or any folder if parentPath==""), grab the *next*
  //    path segment after parentPath.
  final subFolderCounts = <String, int>{}; // key = sub-folder path
  final subFolderPhotoIds = <String, List<String>>{};

  final prefix = parentPath.isEmpty ? '' : '$parentPath/';

  for (final p in photos) {
    if (p.folder == parentPath) {
      direct.add(p);
      continue;
    }
    if (parentPath.isEmpty || p.folder.startsWith(prefix)) {
      final remainder =
          parentPath.isEmpty ? p.folder : p.folder.substring(prefix.length);
      if (remainder.isEmpty) continue;
      final slash = remainder.indexOf('/');
      final firstSeg = slash == -1 ? remainder : remainder.substring(0, slash);
      final subPath = parentPath.isEmpty ? firstSeg : '$parentPath/$firstSeg';
      subFolderCounts[subPath] = (subFolderCounts[subPath] ?? 0) + 1;
      (subFolderPhotoIds[subPath] ??= <String>[]).add(p.id);
    }
  }

  final subFolderStacks = _pickPreviewStack(subFolderPhotoIds, seed, 4);
  final subFolders = subFolderCounts.entries.map((e) {
    final stack = subFolderStacks[e.key] ?? const <String>[];
    return CatalogFolder(
      path: e.key,
      photoCount: e.value,
      coverThumbPath: stack.isEmpty ? null : stack.first,
      previewThumbPaths: stack.length > 1 ? stack.sublist(1) : const <String>[],
    );
  }).toList()
    ..sort((a, b) =>
        a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()));

  direct.sort(
      (a, b) => a.filename.toLowerCase().compareTo(b.filename.toLowerCase()));

  return (subFolders: subFolders, directPhotos: direct);
});

/// Fires a fast, single-folder Drive refresh for [folderPath] the moment it's
/// watched, then surfaces the freshly-upserted rows. The DAILY UPDATE folder
/// watches this so it shows today's latest designs the instant it's opened —
/// whether reached via the 9 PM notification tap or by browsing in — instead of
/// waiting for a full catalog re-walk or a manual pull-to-refresh.
///
/// autoDispose: re-runs on every entry into the folder, torn down on exit.
/// Cheap — just one extra Drive folder listing.
final folderLiveRefreshProvider =
    FutureProvider.autoDispose.family<void, String>((ref, folderPath) async {
  final refreshed =
      await ref.read(catalogServiceProvider).refreshSingleFolder(folderPath);
  if (refreshed) {
    // Re-read SQLite so the new designs paint immediately; this also kicks the
    // cache path, which runs price-OCR for them + a full background sync.
    ref.invalidate(catalogProvider);
  }
});

/// Favorites.
class FavoritesNotifier extends StateNotifier<Set<String>> {
  FavoritesNotifier(this._service, this._ref) : super(const {}) {
    _hydrate();
  }
  final FavoritesService _service;
  final Ref _ref;

  Future<void> _hydrate() async {
    state = await _service.load();
    // Selections only live with the cart — drop any left over from a cart
    // that was emptied (owner saw "SELECTED" with an empty cart).
    final picks = _ref.read(picksProvider);
    for (final id in picks.keys.toList()) {
      if (!state.contains(id)) await _ref.read(picksProvider.notifier).remove(id);
    }
  }

  bool isFavorite(String id) => state.contains(id);

  Future<void> toggle(String id) async {
    final isNow = !state.contains(id);
    state = isNow ? {...state, id} : (state.where((x) => x != id).toSet());
    await _service.setStarred(id, isNow);
    // Removing from cart also wipes any saved markup so the photo reverts to
    // its fresh Drive thumbnail. If the customer re-adds it, they start over
    // on a clean image.
    if (!isNow) {
      await _ref.read(picksProvider.notifier).remove(id);
      await _ref.read(editsProvider.notifier).markRemoved(id);
    }
  }

  Future<void> clear() async {
    final removedIds = state.toList();
    for (final id in removedIds) {
      await _ref.read(picksProvider.notifier).remove(id);
    }
    state = const {};
    await _service.clear();
    // Also wipe every edit so the photos revert to their unedited versions.
    final editsNotifier = _ref.read(editsProvider.notifier);
    for (final id in removedIds) {
      await editsNotifier.markRemoved(id);
    }
  }

  /// Drops any cart entry whose photo is no longer in [validIds] — e.g. the
  /// design was deleted from Google Drive — and wipes its saved markup so
  /// nothing orphaned is left behind.
  ///
  /// ONLY call with an AUTHORITATIVE photo set (a complete scrape or a fully
  /// loaded cache). Passing a partial scrape would wrongly evict still-valid
  /// designs, so the empty-set case is ignored as a safety guard.
  Future<void> reconcile(Set<String> validIds) async {
    if (validIds.isEmpty) return;
    // Use the persisted set if the notifier hasn't hydrated yet.
    final current = state.isEmpty ? await _service.load() : state;
    final stale = current.where((id) => !validIds.contains(id)).toList();
    if (stale.isEmpty) return;
    final editsNotifier = _ref.read(editsProvider.notifier);
    for (final id in stale) {
      await _service.setStarred(id, false);
      await editsNotifier.markRemoved(id);
    }
    state = current.where(validIds.contains).toSet();
  }
}

final favoritesProvider =
    StateNotifierProvider<FavoritesNotifier, Set<String>>((ref) {
  return FavoritesNotifier(ref.watch(favoritesServiceProvider), ref);
});

/// Filter state.
class FilterNotifier extends StateNotifier<FilterState> {
  FilterNotifier() : super(const FilterState());
  void setQuery(String q) => state = state.copyWith(query: q);
  void setPriceRange(RangeValues r) => state = state.copyWith(priceRange: r);
  void toggleFolder(String f) {
    final next = {...state.folders};
    if (!next.add(f)) next.remove(f);
    state = state.copyWith(folders: next);
  }

  void setFolders(Set<String> f) => state = state.copyWith(folders: f);
  void toggleFavoritesOnly() =>
      state = state.copyWith(favoritesOnly: !state.favoritesOnly);
  void setSort(SortBy by, {bool? asc}) =>
      state = state.copyWith(sortBy: by, sortAsc: asc ?? state.sortAsc);
  void toggleCategory(String c) {
    final next = {...state.categories};
    if (!next.add(c)) next.remove(c);
    state = state.copyWith(categories: next);
  }

  void clear() => state = const FilterState();
}

final filterProvider = StateNotifierProvider<FilterNotifier, FilterState>(
    (ref) => FilterNotifier());

/// Filtered + sorted photos.
final filteredPhotosProvider = Provider<List<Photo>>((ref) {
  final photos = ref.watch(photosProvider);
  final filter = ref.watch(filterProvider);
  final favs = ref.watch(favoritesProvider);

  final rawQuery = filter.query.trim();
  final normQuery = _alnumOnly(rawQuery);
  bool matchesText(Photo p) {
    if (normQuery.isEmpty) return true;
    if (_alnumOnly(p.fabricName ?? '').contains(normQuery)) return true;
    if (_alnumOnly(p.filename).contains(normQuery)) return true;
    if (_alnumOnly(p.designNumber ?? '').contains(normQuery)) return true;
    return false;
  }

  bool matchesPrice(Photo p) {
    if (filter.priceRange.min <= 0 && !filter.priceRange.max.isFinite)
      return true;
    final price = p.price;
    if (price == null) return false;
    if (price < filter.priceRange.min) return false;
    if (filter.priceRange.max.isFinite && price > filter.priceRange.max)
      return false;
    return true;
  }

  bool matchesFolder(Photo p) {
    if (filter.folders.isEmpty) return true;
    return filter.folders.any(
        (f) => p.folder == f || p.folder.startsWith('$f/') || p.topFolder == f);
  }

  bool matchesFav(Photo p) {
    if (!filter.favoritesOnly) return true;
    return favs.contains(p.id);
  }

  bool matchesCategory(Photo p) {
    if (filter.categories.isEmpty) return true;
    return filter.categories.contains(fabricCategoryOf(p.topFolder));
  }

  final filtered = photos
      .where((p) =>
          matchesText(p) &&
          matchesPrice(p) &&
          matchesFolder(p) &&
          matchesFav(p) &&
          matchesCategory(p))
      .toList();

  // Pre-compute fabric-name counts if needed by the sort below.
  Map<String, int>? fabricCounts;
  if (filter.sortBy == SortBy.fabricName) {
    fabricCounts = <String, int>{};
    for (final p in filtered) {
      final n = p.fabricName;
      if (n != null && n.isNotEmpty) {
        fabricCounts[n] = (fabricCounts[n] ?? 0) + 1;
      }
    }
  }

  int cmp(Photo a, Photo b) {
    switch (filter.sortBy) {
      case SortBy.shuffle:
        // Keep the natural order here; the folder/all views apply a per-open
        // random shuffle on top (so it's fresh each time a folder is opened).
        return 0;
      case SortBy.folderThenName:
        final c = a.folder.compareTo(b.folder);
        if (c != 0) return c;
        return a.filename.toLowerCase().compareTo(b.filename.toLowerCase());
      case SortBy.priceAsc:
        return (a.price ?? 1 << 30).compareTo(b.price ?? 1 << 30);
      case SortBy.priceDesc:
        return (b.price ?? -1).compareTo(a.price ?? -1);
      case SortBy.modifiedDesc:
        return Photo.compareNewestFirst(a, b);
      case SortBy.designNumber:
        return (a.designNumber ?? '').compareTo(b.designNumber ?? '');
      case SortBy.fabricName:
        // Group by fabric name. The fabric name with the MOST photos comes
        // first; ties break alphabetically; photos without a fabric name at
        // the end.
        final an = a.fabricName;
        final bn = b.fabricName;
        if (an == null && bn == null) return 0;
        if (an == null) return 1;
        if (bn == null) return -1;
        final ac = fabricCounts![an] ?? 0;
        final bc = fabricCounts![bn] ?? 0;
        if (ac != bc) return bc.compareTo(ac); // count desc
        final byName = an.toLowerCase().compareTo(bn.toLowerCase());
        if (byName != 0) return byName;
        // Stable within a group: by filename.
        return a.filename.toLowerCase().compareTo(b.filename.toLowerCase());
    }
  }

  filtered.sort(cmp);
  if (!filter.sortAsc &&
      filter.sortBy != SortBy.priceDesc &&
      filter.sortBy != SortBy.modifiedDesc) {
    return filtered.reversed.toList();
  }
  return filtered;
});

/// Owner, 11-Oct-2026: the 50 NEWEST designs carry a NEW badge; when a new
/// design arrives the oldest of the 50 drops out.
const int kNewBadgeCount = 50;
final newDesignIdsProvider = Provider<Set<String>>((ref) {
  final photos = [...ref.watch(photosProvider)];
  photos.sort((a, b) => (b.driveModified ?? b.lastSeen)
      .compareTo(a.driveModified ?? a.lastSeen));
  return photos.take(kNewBadgeCount).map((p) => p.id).toSet();
});

/// Multi-selection state.
class SelectionNotifier extends StateNotifier<Set<String>> {
  SelectionNotifier() : super(const {});
  bool get isActive => state.isNotEmpty;
  void toggle(String id) {
    HapticFeedback.selectionClick();
    final s = {...state};
    if (!s.add(id)) s.remove(id);
    state = s;
  }

  void selectAll(Iterable<String> ids) {
    HapticFeedback.selectionClick();
    state = ids.toSet();
  }

  void clear() => state = const {};
}

final selectionProvider = StateNotifierProvider<SelectionNotifier, Set<String>>(
    (ref) => SelectionNotifier());

/// Min/max price bounds for the price slider.
final priceBoundsProvider = Provider<({double min, double max})>((ref) {
  final photos = ref.watch(photosProvider);
  if (photos.isEmpty) return (min: 0, max: 5000);
  int lo = 1 << 30, hi = 0;
  for (final p in photos) {
    final pr = p.price;
    if (pr == null) continue;
    if (pr < lo) lo = pr;
    if (pr > hi) hi = pr;
  }
  if (hi == 0) return (min: 0, max: 5000);
  final niceHi = ((hi + 499) ~/ 500) * 500;
  return (min: lo.toDouble(), max: niceHi.toDouble());
});
