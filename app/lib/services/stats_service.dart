import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Owner 25-Oct: which designs customers LOOK at and put in the cart — the
/// weekly "what's hot" report for the shop. Counted on the phone, sent with
/// the account-status call the app already makes at every open (no extra
/// network calls, nothing personal: design numbers + counts only).
class Stats {
  static const _k = 'stats_v1';

  static Future<Map<String, dynamic>> pending() async {
    try {
      final p = await SharedPreferences.getInstance();
      final m = jsonDecode(p.getString(_k) ?? '{}');
      return m is Map<String, dynamic> ? m : {};
    } catch (_) {
      return {};
    }
  }

  /// kind = 'views' | 'carts'.
  static Future<void> bump(String kind, String? design) async {
    final d = (design ?? '').trim().toUpperCase();
    if (d.isEmpty) return;
    try {
      final p = await SharedPreferences.getInstance();
      final m = await pending();
      final sub = Map<String, dynamic>.from(m[kind] as Map? ?? {});
      if (sub.length >= 300 && !sub.containsKey(d)) return; // never grows without bound
      sub[d] = ((sub[d] as num?) ?? 0) + 1;
      m[kind] = sub;
      await p.setString(_k, jsonEncode(m));
    } catch (_) {/* counting must never break the app */}
  }

  static Future<void> clear() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.remove(_k);
    } catch (_) {}
  }
}
