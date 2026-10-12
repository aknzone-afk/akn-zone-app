import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config.dart';
import '../models/photo.dart';
import '../providers/providers.dart';

/// How many sarees each catalog photo shows (the open one + every folded
/// colour). Counted once per photo on the shop PC by Gemini
/// (CLE\AKNZonePieces\count_pieces.py, same rule as the AKN Chat bot) and
/// published as `$kWebsiteBase/app/pieces.json`. An order's pieces for a
/// design default to this count, which drives the ₹30,000 minimum.
class PiecesNotifier extends StateNotifier<Map<String, int>> {
  PiecesNotifier(this._prefs, this._dio) : super(_load(_prefs)) {
    refresh();
  }

  final SharedPreferences _prefs;
  final Dio _dio;
  static const _kKey = 'pieces_v1';
  static const _kBoxKey = 'pieces_boxes_v1';
  static const _kPtKey = 'pieces_points_v1';

  /// key → label point per saree [y, x] (0-1000): the centre of a plain,
  /// single-colour part of that saree — where its number is drawn.
  late Map<String, List<List<int>>> _points = _loadPoints(_prefs);

  static Map<String, List<List<int>>> _loadPoints(SharedPreferences prefs) {
    try {
      return _indexPoints(
          jsonDecode(prefs.getString(_kPtKey) ?? '{}') as Map<String, dynamic>);
    } catch (_) {
      return {};
    }
  }

  static Map<String, List<List<int>>> _indexPoints(Map<String, dynamic> raw) {
    final out = <String, List<List<int>>>{};
    raw.forEach((k, v) {
      try {
        final list = (v as List)
            .map((b) => (b as List).map((e) => (e as num).toInt()).toList())
            .toList();
        out[k] = list;
        out.putIfAbsent(_noExt(k), () => list);
      } catch (_) {}
    });
    return out;
  }

  List<List<int>>? pointsFor(Photo p) {
    final k = keyFor(p);
    return _points[k] ?? _points[_noExt(k)];
  }

  /// key → saree boxes [ymin, xmin, ymax, xmax] on a 0-1000 scale.
  late Map<String, List<List<int>>> _boxes = _loadBoxes(_prefs);

  static Map<String, List<List<int>>> _indexBoxes(Map<String, dynamic> raw) {
    final out = <String, List<List<int>>>{};
    raw.forEach((k, v) {
      try {
        final list = (v as List)
            .map((b) => (b as List).map((e) => (e as num).toInt()).toList())
            .where((b) => b.length == 4)
            .toList();
        out[k] = list;
        out.putIfAbsent(_noExt(k), () => list);
      } catch (_) {}
    });
    return out;
  }

  static Map<String, List<List<int>>> _loadBoxes(SharedPreferences prefs) {
    try {
      return _indexBoxes(
          jsonDecode(prefs.getString(_kBoxKey) ?? '{}') as Map<String, dynamic>);
    } catch (_) {
      return {};
    }
  }

  List<List<int>>? boxesFor(Photo p) {
    final k = keyFor(p);
    final found = _boxes[k] ?? _boxes[_noExt(k)];
    final raw = found == null ? null : openAsOne(found);
    final fixed = _fixed[fixKey(p.designNumber)];
    if (raw == null || fixed == null || fixed >= raw.length || fixed < 1) return raw;
    return _mergeTo(raw, fixed);
  }

  /// Owner 12-Oct (rule): the OPEN saree at the top is ALWAYS ONE saree. The
  /// photo-reading often splits it into 2-3 strips (body / pallu / blouse
  /// piece) that all start at the very top — when the photo also has folded
  /// sarees below (4+ found), every box starting in that top band is joined
  /// into one.
  static List<List<int>> openAsOne(List<List<int>> boxes) {
    if (boxes.length < 4) return boxes;
    final top = boxes.map((b) => b[0]).reduce((a, b) => a < b ? a : b);
    final band = [for (final b in boxes) if (b[0] <= top + 120) b];
    if (band.length < 2) return boxes;
    final m = [
      band.map((b) => b[0]).reduce((a, b) => a < b ? a : b),
      band.map((b) => b[1]).reduce((a, b) => a < b ? a : b),
      band.map((b) => b[2]).reduce((a, b) => a > b ? a : b),
      band.map((b) => b[3]).reduce((a, b) => a > b ? a : b),
    ];
    return [m, for (final b in boxes) if (!band.contains(b)) b];
  }

  /// Owner 12-Oct: the shop corrected the count to fewer sarees than the
  /// photo-reading found — an OPEN saree was split into parts (pallu / body).
  /// Join the back-most side-by-side parts (smallest top edge) until the
  /// count matches.
  static List<List<int>> _mergeTo(List<List<int>> boxes, int want) {
    final b = [for (final x in boxes) [...x]];
    while (b.length > want) {
      int? bi, bj;
      var best = 1 << 30;
      for (var i = 0; i < b.length; i++) {
        for (var j = i + 1; j < b.length; j++) {
          final gap = b[i][1] > b[j][3]
              ? b[i][1] - b[j][3]
              : (b[j][1] > b[i][3] ? b[j][1] - b[i][3] : 0);
          if (gap > 60) continue; // must touch side by side
          final score = b[i][0] + b[j][0] + (b[i][0] - b[j][0]).abs() * 2;
          if (score < best) {
            best = score;
            bi = i;
            bj = j;
          }
        }
      }
      if (bi == null || bj == null) break;
      final m = [
        b[bi][0] < b[bj][0] ? b[bi][0] : b[bj][0],
        b[bi][1] < b[bj][1] ? b[bi][1] : b[bj][1],
        b[bi][2] > b[bj][2] ? b[bi][2] : b[bj][2],
        b[bi][3] > b[bj][3] ? b[bi][3] : b[bj][3],
      ];
      b.removeAt(bj);
      b[bi] = m;
    }
    return b;
  }
  static const _kAtKey = 'pieces_at_v1';

  static String _noExt(String s) => s.replaceFirst(RegExp(r'\.[a-z0-9]{2,5}$'), '');

  static String keyFor(Photo p) =>
      (p.folder.isEmpty ? p.filename : '${p.folder}/${p.filename}').toLowerCase();

  static Map<String, int> _index(Map<String, dynamic> raw) {
    final out = <String, int>{};
    raw.forEach((k, v) {
      final n = v is int ? v : int.tryParse('$v');
      if (n == null || n < 1) return;
      out[k] = n;
      out.putIfAbsent(_noExt(k), () => n);
    });
    return out;
  }

  static Map<String, int> _load(SharedPreferences prefs) {
    final s = prefs.getString(_kKey);
    if (s == null) return const {};
    try {
      return _index(jsonDecode(s) as Map<String, dynamic>);
    } catch (_) {
      return const {};
    }
  }

  /// Counts the shop corrected in Telegram ("count T58 (2) 6"), by design no.
  Map<String, int> _fixed = {};
  static String fixKey(String? d) => (d ?? '').toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');

  /// True when the shop corrected this design's count (boxes may be short).
  bool isFixed(Photo p) => _fixed.containsKey(fixKey(p.designNumber));

  Future<void> _loadFixes() async {
    try {
      final r = await _dio.get<dynamic>(
          'https://asia-south1-akn-chat-a7dd8.cloudfunctions.net/countOverrides',
          options: Options(headers: {'x-app-key': 'akn-zone-app-2026'}, responseType: ResponseType.plain));
      final j = jsonDecode('${r.data}') as Map<String, dynamic>;
      final m = Map<String, dynamic>.from((j['counts'] ?? const {}) as Map);
      _fixed = {for (final e in m.entries) e.key: (e.value as num).toInt()};
      await _prefs.setString('pieces_fixed_v1', jsonEncode(_fixed));
    } catch (_) {
      try {
        final m = jsonDecode(_prefs.getString('pieces_fixed_v1') ?? '{}') as Map<String, dynamic>;
        _fixed = {for (final e in m.entries) e.key: (e.value as num).toInt()};
      } catch (_) {}
    }
  }

  int? piecesFor(Photo p) {
    final f = _fixed[fixKey(p.designNumber)];
    if (f != null) return f;
    final k = keyFor(p);
    final n = state[k] ?? state[_noExt(k)];
    // Same rule for the count: the split open saree counts once.
    final found = _boxes[k] ?? _boxes[_noExt(k)];
    if (n != null && found != null && n == found.length) return openAsOne(found).length;
    return n;
  }

  /// Re-downloads the counts at most every 30 minutes (and always when we
  /// have none yet) — new photos get counted on the PC twice a day.
  Future<void> refresh({bool force = false}) async {
    await _loadFixes(); // shop corrections — always fresh (tiny)
    if (mounted) state = Map.of(state);
    final at = _prefs.getInt(_kAtKey) ?? 0;
    final age = DateTime.now().millisecondsSinceEpoch - at;
    if (!force && state.isNotEmpty && age < const Duration(minutes: 30).inMilliseconds) {
      return;
    }
    try {
      final res = await _dio.get<dynamic>(
        '$kWebsiteBase/app/pieces.json?t=${DateTime.now().millisecondsSinceEpoch ~/ 600000}',
        options: Options(responseType: ResponseType.plain),
      );
      final j = jsonDecode('${res.data}') as Map<String, dynamic>;
      final pieces = Map<String, dynamic>.from(j['pieces'] as Map);
      await _prefs.setString(_kKey, jsonEncode(pieces));
      final boxes = Map<String, dynamic>.from((j['boxes'] ?? const {}) as Map);
      await _prefs.setString(_kBoxKey, jsonEncode(boxes));
      _boxes = _indexBoxes(boxes);
      final points = Map<String, dynamic>.from((j['points'] ?? const {}) as Map);
      await _prefs.setString(_kPtKey, jsonEncode(points));
      _points = _indexPoints(points);
      await _prefs.setInt(_kAtKey, DateTime.now().millisecondsSinceEpoch);
      if (mounted) state = _index(pieces);
    } catch (_) {
      // Offline / not published yet — keep what we have.
    }
  }
}

final piecesProvider =
    StateNotifierProvider<PiecesNotifier, Map<String, int>>((ref) {
  return PiecesNotifier(
      ref.watch(sharedPreferencesProvider), ref.watch(dioProvider));
});
