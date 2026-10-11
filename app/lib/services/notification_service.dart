import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

/// Top-level Drive folder the daily notification opens. Create a folder named
/// EXACTLY this in your catalog Drive and drop the day's new designs into it.
const String kDailyUpdateFolder = 'DAILY UPDATE';

const int _dailyHour = 12; // 12:00 PM Sunday, in the customer's local time
const int _dailyMinute = 0;
const int _dailyId = 1001;
const int _testId = 1002;
const String _channelId = 'daily_update';

/// Schedules the daily "new designs" reminder and routes notification taps to
/// the [kDailyUpdateFolder] folder. All failures are swallowed so the catalog
/// keeps working even if notifications aren't available.
class NotificationService {
  NotificationService._();
  static final NotificationService instance = NotificationService._();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  void Function(String payload)? onTap;
  bool _ready = false;

  Future<void> init({void Function(String payload)? onTap}) async {
    this.onTap = onTap;
    if (_ready) return;

    tzdata.initializeTimeZones();
    try {
      final info = await FlutterTimezone.getLocalTimezone();
      tz.setLocalLocation(tz.getLocation(info.identifier));
    } catch (_) {
      tz.setLocalLocation(tz.getLocation('UTC'));
    }

    const settings = InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      iOS: DarwinInitializationSettings(
        requestAlertPermission: false,
        requestBadgePermission: false,
        requestSoundPermission: false,
      ),
    );
    await _plugin.initialize(
      settings: settings,
      onDidReceiveNotificationResponse: (resp) {
        final p = resp.payload;
        if (p != null && p.isNotEmpty) onTap?.call(p);
      },
    );
    _ready = true;
  }

  /// Asks the customer for notification permission (true if granted).
  Future<bool> requestPermission() async {
    if (Platform.isIOS) {
      final ok = await _plugin
          .resolvePlatformSpecificImplementation<
              IOSFlutterLocalNotificationsPlugin>()
          ?.requestPermissions(alert: true, badge: true, sound: true);
      return ok ?? false;
    }
    if (Platform.isAndroid) {
      final ok = await _plugin
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.requestNotificationsPermission();
      return ok ?? false;
    }
    return false;
  }

  /// If the app was cold-launched by a notification tap, returns its payload
  /// so the caller can deep-link after the first frame.
  Future<String?> launchPayload() async {
    final d = await _plugin.getNotificationAppLaunchDetails();
    if (d?.didNotificationLaunchApp ?? false) {
      return d!.notificationResponse?.payload;
    }
    return null;
  }

  NotificationDetails get _details => const NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          'Daily design updates',
          channelDescription:
              'A daily reminder when new designs are added to the catalog.',
          importance: Importance.high,
          priority: Priority.high,
        ),
        iOS: DarwinNotificationDetails(
          presentAlert: true,
          presentBanner: true,
          presentSound: true,
        ),
      );

  /// A notification right now (new message / bill from the shop).
  Future<void> showNow(String title, String body, {String payload = 'chat'}) async {
    if (!_ready) {
      try {
        await init();
      } catch (_) {}
    }
    await _plugin.show(
      id: 7777,
      title: title,
      body: body,
      notificationDetails: _details,
      payload: payload,
    );
  }

  /// Removes the old repeating "new designs" reminder (owner: not wanted).
  Future<void> cancelDaily() async {
    if (!_ready) return;
    await _plugin.cancel(id: _dailyId);
    await _plugin.cancel(id: _testId);
  }

  /// Weekly Sunday 12:00 PM (local) repeating reminder.
  Future<void> scheduleDaily() async {
    if (!_ready) return;
    await _plugin.zonedSchedule(
      id: _dailyId,
      title: 'New designs this week! 🆕',
      body: "Tap to see the latest updates from AKN Zone.",
      scheduledDate: _nextSunday(_dailyHour, _dailyMinute),
      notificationDetails: _details,
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      matchDateTimeComponents: DateTimeComponents.dayOfWeekAndTime,
      payload: kDailyUpdateFolder,
    );
  }

  /// TEMP — fires a one-off test notification ~10s out so the flow can be tried
  /// without waiting until 9 PM. Remove before release.
  Future<void> fireTestSoon() async {
    if (!_ready) return;
    await _plugin.zonedSchedule(
      id: _testId,
      title: 'New designs are in! 🆕 (test)',
      body: "Tap to open today's update.",
      scheduledDate:
          tz.TZDateTime.now(tz.local).add(const Duration(seconds: 10)),
      notificationDetails: _details,
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      payload: kDailyUpdateFolder,
    );
  }

  tz.TZDateTime _nextSunday(int hour, int minute) {
    final now = tz.TZDateTime.now(tz.local);
    var when =
        tz.TZDateTime(tz.local, now.year, now.month, now.day, hour, minute);
    // Advance to the next Sunday (DateTime.sunday == 7).
    while (when.weekday != DateTime.sunday || !when.isAfter(now)) {
      when = when.add(const Duration(days: 1));
    }
    return when;
  }
}
