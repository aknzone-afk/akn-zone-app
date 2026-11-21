import 'dart:convert';

import 'package:dio/dio.dart';

import '../models/photo.dart';
import 'drive_urls.dart';

/// Folder name shown for a design that is not in the app (cart, order
/// screen, the photo's caption in the shop's group).
const String kOldDesignFolder = 'NOT IN APP (approx 2 weeks)';

/// Owner 21-Nov-2026: designs that are NOT in the app (not ready / design
/// over) can still be ordered. The customer types the design number on the
/// order screen and sees its photos from the shop's FULL photo set — the same
/// one the Rate Bolo page shows (public files, an index `photos.json`:
/// design key → photo hashes; a photo is `p/<KEY>_<hash>.jpg`). A picked
/// photo becomes a normal [Photo] with id `rb-<KEY>_<hash>`, so selecting
/// colours / pieces and ordering work exactly as for a catalogue design.
class OldDesigns {
  OldDesigns._();

  static const _sources = [
    'https://aknzone-afk.github.io/rate-bolo/',
    'https://raw.githubusercontent.com/aknzone-afk/rate-bolo/main/', // GitHub Pages unreachable on some networks
  ];

  static Map<String, List<String>>? _index;
  static DateTime _at = DateTime.fromMillisecondsSinceEpoch(0);

  /// "n-254 (a)" → "N254A": letters and digits only, upper case.
  static String keyOf(String typed) => typed.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');

  /// The design itself without a copy letter / colour word: "1444A" → "1444",
  /// "N254RANI" → "N254". Falls back to the whole key.
  static String baseOf(String typed) {
    final k = keyOf(typed);
    return RegExp(r'^[A-Z]{0,3}\d{2,6}').stringMatch(k) ?? k;
  }

  /// The design a CATALOGUE photo belongs to. Its name is the file's name:
  /// "7242 (3)" → "7242", "T56 (10)" → "T56", "7391 (A)" → "7391",
  /// "5257 LIGHT MATCHING" → "5257", "LOTUS (4)" → "LOTUS".
  static String catalogKey(String name) => baseOf(name.split('(').first);

  /// The index, fetched at most every 10 minutes.
  static Future<Map<String, List<String>>> index(Dio dio) async {
    final have = _index;
    if (have != null && DateTime.now().difference(_at) < const Duration(minutes: 10)) return have;
    Object? last;
    for (final base in _sources) {
      try {
        final r = await dio.get<String>('${base}photos.json?t=${DateTime.now().millisecondsSinceEpoch ~/ 600000}',
            options: Options(responseType: ResponseType.plain, receiveTimeout: const Duration(seconds: 15)));
        final parsed = parseIndex(r.data ?? '');
        if (parsed.isEmpty) continue;
        _index = parsed;
        _at = DateTime.now();
        return parsed;
      } catch (e) {
        last = e;
      }
    }
    if (have != null) return have; // an older copy beats nothing
    throw last ?? StateError('design photo index not reachable');
  }

  static Map<String, List<String>> parseIndex(String body) {
    final j = jsonDecode(body);
    final p = j is Map ? j['p'] : null;
    if (p is! Map) return const {};
    return {
      for (final e in p.entries)
        if (e.value is List)
          keyOf('${e.key}'): [
            for (final h in e.value as List)
              if (RegExp(r'^[0-9a-f]{6,16}$').hasMatch('$h')) '$h',
          ],
    };
  }

  /// Photo ids for what the customer typed (exact design first, then the
  /// design without its copy letter). Empty = no photo of that design.
  static List<String> idsIn(Map<String, List<String>> idx, String typed) {
    final key = keyOf(typed);
    if (key.isEmpty) return const [];
    for (final k in {key, baseOf(key)}) {
      final list = idx[k];
      if (list != null && list.isNotEmpty) {
        return [for (final h in list) '${DriveUrls.oldPrefix}${k}_$h'];
      }
    }
    return const [];
  }

  static Future<List<String>> idsFor(Dio dio, String typed) async => idsIn(await index(dio), typed);

  /// "rb-N254_5641ee46" → "N254".
  static String designOf(String id) {
    final s = id.startsWith(DriveUrls.oldPrefix) ? id.substring(DriveUrls.oldPrefix.length) : id;
    final i = s.lastIndexOf('_');
    return i <= 0 ? s : s.substring(0, i);
  }

  /// The [Photo] the rest of the app works with. No price: the shop quotes
  /// it (the order says "without price"), and it counts ₹0 towards the
  /// minimum like every unpriced design.
  static Photo photoOf(String id) {
    final d = designOf(id);
    return Photo(
      id: id,
      filename: '$d.jpg',
      folder: kOldDesignFolder,
      designNumber: d,
      fabricName: null,
      price: null,
      priceText: null,
      ocrText: '',
      ocrState: OcrState.done,
      lastSeen: 0,
    );
  }
}
