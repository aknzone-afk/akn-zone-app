import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Transport help on the order form (owner, 11-Oct-2026), from the shop's
/// own Tally bills (published daily by the shop PC, transport_web.py):
/// each transport's GST number, and which transports the shop's parties use
/// for each place ("JALGAON → VRL, …").
class TransportInfo {
  static const _url = 'https://aknzone-afk.github.io/akn-zone-data/app/transport-info.json';
  static const _kCache = 'transport_info_v1';

  final Map<String, String> gst;
  final Map<String, List<(String, int)>> dest;
  final Map<String, List<(String, int)>> to;
  /// Owner 16-Oct: the ONLY transports a customer may choose (pick-only):
  /// Tally transporters with a GST number + COURIER + "... TRAVELS".
  final List<String> pick;
  TransportInfo(this.gst, this.dest, this.to, [this.pick = const []]);

  /// Is [t] one of the allowed transports? (no list yet = old behaviour)
  bool allowed(String t) => pick.isEmpty || pick.contains(_n(t));

  /// Owner 18-Oct: COMPULSORY pick — [t] must be in the online list, or in
  /// the bundled list while the online one has not loaded yet.
  static bool ok(TransportInfo? info, List<String> bundled, String t) {
    final n = _n(t);
    if (n.isEmpty) return false;
    final list = (info != null && info.pick.isNotEmpty) ? info.pick : bundled;
    return list.map(_n).contains(n);
  }

  /// The list the transport box offers: [pick] when published, else [fallback].
  List<String> choices(List<String> fallback) => pick.isNotEmpty ? pick : fallback;

  /// Search with spelling slips: "KARTARA" still finds KATARIA TRANSPORT.
  static List<String> search(List<String> opts, String query, {int max = 40}) {
    final q = _n(query);
    if (q.isEmpty) return opts.take(max).toList();
    final words = q.split(' ');
    final starts = <String>[], has = <String>[];
    for (final o in opts) {
      if (!words.every(o.contains)) continue;
      (o.startsWith(q) ? starts : has).add(o);
    }
    final near = <(String, int)>[];
    final w0 = words.first;
    if (w0.length >= 3) {
      final lim = w0.length <= 4 ? 1 : 2;
      for (final o in opts) {
        if (starts.contains(o) || has.contains(o)) continue;
        var best = 99;
        for (final w in o.split(RegExp(r'[^A-Z0-9]+'))) {
          if (w.length < 3) continue;
          final d = _lev(w0, w.length > w0.length + 2 ? w.substring(0, w0.length) : w);
          if (d < best) best = d;
        }
        if (best <= lim) near.add((o, best));
      }
      near.sort((a, b) => a.$2.compareTo(b.$2));
    }
    return [...starts, ...has, ...near.map((e) => e.$1)].take(max).toList();
  }

  static int _lev(String a, String b) {
    var prev = List<int>.generate(b.length + 1, (i) => i);
    for (var i = 1; i <= a.length; i++) {
      final cur = List<int>.filled(b.length + 1, 0)..[0] = i;
      for (var j = 1; j <= b.length; j++) {
        final c = a[i - 1] == b[j - 1] ? 0 : 1;
        final x = prev[j] + 1, y = cur[j - 1] + 1, z = prev[j - 1] + c;
        cur[j] = x < y ? (x < z ? x : z) : (y < z ? y : z);
      }
      prev = cur;
    }
    return prev[b.length];
  }

  static TransportInfo? _mem;

  static TransportInfo? _parse(String raw) {
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      List<(String, int)> pairs(dynamic l) =>
          [for (final e in (l as List)) ('${e[0]}', (e[1] as num).toInt())];
      return TransportInfo(
        {for (final e in (j['gst'] as Map).entries) '${e.key}': '${e.value}'},
        {for (final e in (j['dest'] as Map).entries) '${e.key}': pairs(e.value)},
        {for (final e in (j['to'] as Map).entries) '${e.key}': pairs(e.value)},
        [for (final x in (j['pick'] as List? ?? const [])) '$x'],
      );
    } catch (_) {
      return null;
    }
  }

  /// Cached copy at once; a fresh copy from the website when reachable.
  static Future<TransportInfo?> load(SharedPreferences prefs, Dio dio) async {
    if (_mem != null) return _mem;
    final cached = prefs.getString(_kCache);
    if (cached != null) _mem = _parse(cached);
    try {
      final r = await dio.get<String>(_url,
          options: Options(responseType: ResponseType.plain, receiveTimeout: const Duration(seconds: 15)));
      final fresh = r.data == null ? null : _parse(r.data!);
      if (fresh != null) {
        _mem = fresh;
        await prefs.setString(_kCache, r.data!);
      }
    } catch (_) {}
    return _mem;
  }

  static String _n(String s) => s.toUpperCase().replaceAll(RegExp(r'\s+'), ' ').trim();

  String? gstOf(String transport) => gst[_n(transport)];

  /// Transports used for a place (best spelling match), most bills first.
  List<(String, int)> forPlace(String place) {
    final q = _n(place);
    if (q.length < 3) return const [];
    final hit = dest[q];
    if (hit != null) return hit;
    for (final e in dest.entries) {
      if (q.length >= 4 && (e.key.startsWith(q) || q.startsWith(e.key))) return e.value;
    }
    return const [];
  }

  List<(String, int)> placesOf(String transport) => to[_n(transport)] ?? const [];
}
