import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Transport help on the order form (owner, 11-Oct-2026), from the shop's
/// own Tally bills (published daily by the shop PC, transport_web.py):
/// each transport's GST number, and which transports the shop's parties use
/// for each place ("JALGAON → VRL, …").
class TransportInfo {
  static const _url = 'https://bbsynthetics.in/app/transport-info.json';
  static const _kCache = 'transport_info_v1';

  final Map<String, String> gst;
  final Map<String, List<(String, int)>> dest;
  final Map<String, List<(String, int)>> to;
  TransportInfo(this.gst, this.dest, this.to);

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
