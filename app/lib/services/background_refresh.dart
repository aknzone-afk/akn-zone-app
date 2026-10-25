import 'dart:io';

import 'chat_service.dart';
import 'notification_service.dart';
import 'order_service.dart';
import 'package:dio/dio.dart';
import 'photo_freshness.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';

import '../config.dart';
import 'catalog_service.dart';
import 'drive_scraper.dart';
import 'local_cache.dart';
import 'seed_loader.dart';

/// Unique task name registered with WorkManager.
const String kBackgroundTaskName = 'catalog_periodic_refresh';

/// Refresh cadence on Android. Periodic tasks have a 15-min minimum and
/// flex period of up to the same duration, so the OS may fire anywhere in
/// the window [period - flex, period]. 2 hours is the spec.
const Duration kBackgroundPeriod = Duration(hours: 2);
const String kChatTaskName = 'aknz.chat.check';
const String kOrderResendTask = 'aknz.order.resend';

/// The active refresh window in the device's local time zone.
const int kWindowStartHour = 10; // 10:00 inclusive
const int kWindowEndHour = 20; // up to 20:30
const int kWindowEndMinute = 30;

bool _isInsideWindow(DateTime now) {
  final startMins = kWindowStartHour * 60;
  final endMins = kWindowEndHour * 60 + kWindowEndMinute;
  final mins = now.hour * 60 + now.minute;
  return mins >= startMins && mins <= endMins;
}

/// Entry point that WorkManager calls in a separate background isolate.
/// Must be a top-level (or static) function annotated `@pragma('vm:entry-point')`.
@pragma('vm:entry-point')
void backgroundCallbackDispatcher() {
  Workmanager().executeTask((taskName, inputData) async {
    // Owner 25-Oct: an order still waiting on this phone goes out from the
    // background too (app closed) — every task run tries, never throws.
    try {
      final prefs = await SharedPreferences.getInstance();
      await OrderService.retryPending(prefs, Dio());
    } catch (_) {}
    if (taskName == kChatTaskName) {
      try {
        final prefs = await SharedPreferences.getInstance();
        // Real push registered → the phone already rang for every message;
        // this 15-min check is only the fallback for phones without push.
        if (prefs.getString('push_registered_v1') == null) {
          await ChatService.notifyNew(prefs, Dio(), (t, b) => NotificationService.instance.showNow(t, b));
        }
      } catch (_) {}
      return true;
    }
    if (taskName != kBackgroundTaskName) return true;

    final now = DateTime.now();
    if (!_isInsideWindow(now)) {
      // Outside the user-defined refresh window — quietly do nothing.
      return true;
    }

    try {
      await _runRefreshOnce();
    } catch (_) {
      // Never throw out of a background task — that triggers WorkManager retry
      // backoff. We'd rather quietly skip and try again at the next period.
    }
    return true;
  });
}

/// Background refresh: scrape Drive → persist to SQLite → top up the shared
/// thumbnail cache for any newly-discovered photos. Skips OCR (UI does it).
Future<void> _runRefreshOnce() async {
  final prefs = await SharedPreferences.getInstance();
  final cache = LocalCache();
  final scraper = DriveScraper(
    dio: Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 25),
      receiveTimeout: const Duration(seconds: 40),
      headers: {
        'User-Agent': 'Mozilla/5.0 (Android Background) CatalogApp/1.0'
      },
    )),
  );
  final catalog = CatalogService(
    scraper: scraper,
    cache: cache,
    prefs: prefs,
    seedLoader: SeedLoader(),
  );
  final result = await catalog.load(force: true);
  await _prefetchAllThumbnailsBg(result.photos.map((p) => p.id));
}

/// Mirror of providers.dart's `_prefetchAllThumbnails` but for the background
/// isolate. Walks every photo id and downloads its thumbnail into the shared
/// `flutter_cache_manager` disk cache, in parallel, skipping anything already
/// on disk.
Future<void> _prefetchAllThumbnailsBg(Iterable<String> ids) async {
  final manager = photoCacheManager;
  final queue = ids.toList();
  if (queue.isEmpty) return;

  Future<void> worker() async {
    while (queue.isNotEmpty) {
      final id = queue.removeAt(0);
      final url =
          'https://drive.google.com/thumbnail?id=$id&sz=w$kThumbnailWidth';
      try {
        final cached = await manager.getFileFromCache(url);
        if (cached != null) continue;
        await manager.downloadFile(url);
      } catch (_) {/* non-fatal */}
    }
  }

  const concurrency = 12;
  await Future.wait(List.generate(concurrency, (_) => worker()));
}

class BackgroundRefresh {
  /// One-time setup at app launch. Idempotent — safe to call every cold start.
  static Future<void> register() async {
    // iPhone: WorkManager needs BGTaskScheduler ids we never declared — it
    // would only log errors. Push + the foreground checks cover iOS.
    if (!Platform.isAndroid) return;
    await Workmanager().initialize(
      backgroundCallbackDispatcher,
      isInDebugMode: false,
    );
    // Shop messages (bill → "Sir, please make the payment") — every 15 min, any hour.
    await Workmanager().registerPeriodicTask(
      kChatTaskName,
      kChatTaskName,
      frequency: const Duration(minutes: 15),
      constraints: Constraints(networkType: NetworkType.connected),
      existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
    );
    await Workmanager().registerPeriodicTask(
      kBackgroundTaskName,
      kBackgroundTaskName,
      frequency: kBackgroundPeriod,
      initialDelay: const Duration(minutes: 5),
      constraints: Constraints(
        networkType: NetworkType.connected,
        requiresBatteryNotLow: false,
        requiresCharging: false,
        requiresDeviceIdle: false,
        requiresStorageNotLow: false,
      ),
      backoffPolicy: BackoffPolicy.linear,
      backoffPolicyDelay: const Duration(minutes: 10),
      existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
      tag: 'catalog_refresh',
    );
  }

  /// Owner 25-Oct: an order is being sent — if the app is closed before it
  /// finishes, Android runs this one-off task within minutes and
  /// retryPending completes the send from the background (the cloud's own
  /// 3-minute safety net covers the rest, and iPhones).
  static Future<void> scheduleOrderResend() async {
    if (!Platform.isAndroid) return;
    try {
      await Workmanager().registerOneOffTask(
        kOrderResendTask,
        kOrderResendTask,
        initialDelay: const Duration(minutes: 2),
        constraints: Constraints(networkType: NetworkType.connected),
        existingWorkPolicy: ExistingWorkPolicy.replace,
        backoffPolicy: BackoffPolicy.linear,
        backoffPolicyDelay: const Duration(minutes: 5),
      );
    } catch (_) {}
  }

  static Future<void> cancelOrderResend() async {
    if (!Platform.isAndroid) return;
    try {
      await Workmanager().cancelByUniqueName(kOrderResendTask);
    } catch (_) {}
  }

  /// Remove the scheduled task (e.g. from a future Settings toggle).
  static Future<void> unregister() async {
    await Workmanager().cancelByUniqueName(kBackgroundTaskName);
  }
}

// Re-export for tests and the foreground caller.
bool isInsideRefreshWindow(DateTime t) => _isInsideWindow(t);
