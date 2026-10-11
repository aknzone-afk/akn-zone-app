import 'package:app_badge_plus/app_badge_plus.dart';

/// The red number on the app icon = unread shop messages (owner 11-Oct-2026).
class AppBadge {
  static int _last = -1;
  static Future<void> set(int n) async {
    if (n == _last) return;
    _last = n;
    try {
      if (await AppBadgePlus.isSupported()) await AppBadgePlus.updateBadge(n);
    } catch (_) {}
  }
}
