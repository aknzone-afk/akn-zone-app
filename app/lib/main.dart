import 'package:flutter/material.dart';

import 'l10n.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app.dart';
import 'config.dart';
import 'providers/providers.dart';
import 'services/background_refresh.dart';
import 'services/notification_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Lock app to portrait orientation.
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);
  final prefs = await SharedPreferences.getInstance();
  loadLanguage(prefs);

  assert(
    kDriveFolderId.isNotEmpty && !kDriveFolderId.contains('REPLACE'),
    'You must set kDriveFolderId in lib/config.dart before running the app.',
  );

  // Register the every-2-hour background refresh (10:00-20:30 window).
  // No notifications, no foreground service — uses WorkManager only.
  try {
    await BackgroundRefresh.register();
  } catch (_) {
    // Background refresh registration failures are non-fatal; foreground
    // pull-to-refresh still works.
  }

  // Daily 9 PM "new designs" reminder → opens the DAILY UPDATE folder on tap.
  // Only schedule for users who pass the geofence gate — Surat-based people
  // who can't enter the app shouldn't receive the notification.
  // Non-fatal: the catalog still works if notifications are denied/unavailable.
  String? launchPayload;
  try {
    await NotificationService.instance.init(onTap: _openDailyUpdate);
    await NotificationService.instance.requestPermission();
    final geoAllowed = prefs.getBool('geo_check_allowed') ?? true;
    if (geoAllowed) {
      await NotificationService.instance.scheduleDaily();
    }
    launchPayload = await NotificationService.instance.launchPayload();
  } catch (_) {}

  // A root container we can reach from the notification handler so tapping the
  // daily reminder can force a fresh Drive scrape.
  final container = ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
    ],
  );
  _rootContainer = container;
  runApp(
    UncontrolledProviderScope(
      container: container,
      child: const CatalogApp(),
    ),
  );

  // Cold-launched by tapping the notification → open the folder after frame 1.
  if (launchPayload != null && launchPayload.isNotEmpty) {
    final p = launchPayload;
    WidgetsBinding.instance.addPostFrameCallback((_) => _openDailyUpdate(p));
  }
}

/// Root provider container, so the notification handler can force a refresh.
ProviderContainer? _rootContainer;

/// Opens the daily-update folder from a notification tap AND pulls the latest
/// from Drive on the spot, so the folder reflects exactly what's there now.
void _openDailyUpdate(String payload) {
  // Open the folder immediately so the tap feels instant (cached view first),
  // then refresh in the background.
  appRouter.push('/folder/${Uri.encodeComponent(payload)}');
  final c = _rootContainer;
  if (c == null) return;
  // FAST PATH: refresh ONLY this one folder from Drive (1–2 requests) and
  // surface it right away — instead of waiting for a full catalog re-walk,
  // which is why the folder used to keep showing yesterday's designs until the
  // whole slow scrape finished. Invalidating the catalog afterwards also kicks
  // off price-OCR for the new designs + a full background sync via the cache
  // path, so removals and prices catch up on their own.
  // ignore: discarded_futures
  c
      .read(catalogServiceProvider)
      .refreshSingleFolder(payload)
      .then((_) => c.invalidate(catalogProvider))
      .catchError((_) => c.invalidate(catalogProvider));
}
