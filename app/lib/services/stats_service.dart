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

  /// Owner 27-Oct: where a customer stops on the way to an order —
  /// 'cart_open', 'cart_blocked' (below ₹30,000), 'order_open',
  /// 'order_blocked', 'order_sent', 'hot_tap'. Counts only.
  static Future<void> step(String name) async {
    try {
      final p = await SharedPreferences.getInstance();
      final m = await pending();
      final sub = Map<String, dynamic>.from(m['steps'] as Map? ?? {});
      sub[name] = ((sub[name] as num?) ?? 0) + 1;
      m['steps'] = sub;
      await p.setString(_k, jsonEncode(m));
    } catch (_) {}
  }

  /// Owner 27-Oct: this week's popular designs (from the status call) —
  /// shown under the ₹30,000 bar.
  static const _kHot = 'hot_v1';
  static Future<void> saveHot(List hot) async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setStringList(_kHot, [for (final x in hot.take(20)) '$x']);
    } catch (_) {}
  }

  static List<String> hot(SharedPreferences p) {
    try {
      return p.getStringList(_kHot) ?? const [];
    } catch (_) {
      return const [];
    }
  }

  /// Owner 25-Oct (point 5): the cart — how many designs, and when it last
  /// changed — goes with the status call for the "waiting in your cart" push.
  static const _kCart = 'cart_snap_v1';
  static Future<void> cart(int n) async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(_kCart, jsonEncode({'n': n, 'at': DateTime.now().millisecondsSinceEpoch}));
    } catch (_) {}
  }

  static Future<Map<String, dynamic>?> cartSnap() async {
    try {
      final p = await SharedPreferences.getInstance();
      final m = jsonDecode(p.getString(_kCart) ?? 'null');
      return m is Map<String, dynamic> ? m : null;
    } catch (_) {
      return null;
    }
  }

  static Future<void> clear() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.remove(_k);
    } catch (_) {}
  }
}
