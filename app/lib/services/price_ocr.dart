import 'dart:async';

import 'package:dio/dio.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

import '../config.dart';
import 'drive_urls.dart';
import 'photo_freshness.dart';

/// Downloads a photo at OCR-friendly resolution, runs ML Kit text recognition
/// on it, and returns the smallest price found (or null if none).
///
/// Only the price is extracted — fabric name OCR was removed per user request.
class PriceOcr {
  final Dio _dio;
  final TextRecognizer _recognizer;

  PriceOcr({required Dio dio})
      : _dio = dio,
        _recognizer = TextRecognizer(script: TextRecognitionScript.latin);

  void close() => _recognizer.close();

  /// Full-size fallback reads run one at a time across all readers, so a batch
  /// of hard-to-read photos can't pile up full-resolution bitmaps at once.
  static Future<void> _fallbackTail = Future.value();

  static Future<T> _oneAtATime<T>(Future<T> Function() task) {
    final run = _fallbackTail.then((_) => task());
    _fallbackTail = run.then((_) {}, onError: (_) {});
    return run;
  }

  /// Reads the price from the photo's grid thumbnail (always the current file
  /// — see [kThumbnailWidth]) and returns the Drive [version] it was read from.
  /// If no price is found there, the full-size image is tried once; if that
  /// can't be fetched the read counts as failed so it is retried later.
  Future<
      ({
        String text,
        int? price,
        String? priceText,
        bool ok,
        String? version
      })> recognize(String driveFileId) async {
    const failed =
        (text: '', price: null, priceText: null, ok: false, version: null);
    final grid = await _readAt(driveFileId, kThumbnailWidth);
    if (grid == null) return failed;
    var best = grid;
    if (grid.price == null) {
      final full =
          await _oneAtATime(() => _readAt(driveFileId, kDetailImageWidth));
      if (full == null) return failed;
      if (full.price != null) best = full;
    }
    final version = grid.version ??
        (await fetchDriveVersion(_dio, driveFileId)).version;
    return (
      text: best.text,
      price: best.price,
      priceText: best.priceText,
      ok: true,
      version: version,
    );
  }

  /// Fetches the image at [width] through the shared photo cache (a
  /// conditional request when it's already cached, so the grid and this read
  /// share one download and always see the same picture) and OCRs it.
  /// Null if the download or OCR failed.
  Future<({String text, int? price, String? priceText, String? version})?>
      _readAt(String driveFileId, int width) async {
    try {
      final url = DriveUrls.thumbnail(driveFileId, width: width);
      final info = await photoCacheManager
          .downloadFile(url)
          .timeout(const Duration(seconds: 60));
      final result = await _recognizer
          .processImage(InputImage.fromFilePath(info.file.path));
      final parsed = parsePrice(result.text);
      final version = await cachedImageVersion(url);
      return (
        text: result.text,
        price: parsed.$1,
        priceText: parsed.$2,
        version: (version == null || version.isEmpty) ? null : version,
      );
    } catch (_) {
      return null;
    }
  }
}

/// Repairs common OCR misreads inside number runs so a price like "1970" is not
/// truncated to "197". ML Kit frequently reads a trailing "0" as the letter
/// O/o/Q, or splits the digits with a stray space ("197 0"). This only affects
/// price parsing — never the text shown to the user.
String _repairDigits(String text) {
  var t = text;
  // Letter O / o / Q touching a digit → zero ("197O" → "1970"). Two passes so
  // runs like "19OO" are fully repaired.
  for (var i = 0; i < 2; i++) {
    t = t.replaceAllMapped(RegExp(r'(\d)[OoQ]'), (m) => '${m[1]}0');
    t = t.replaceAllMapped(RegExp(r'[OoQ](\d)'), (m) => '0${m[1]}');
  }
  // Digits split by spaces/commas right before a "/-" suffix → joined
  // ("197 0 /-" → "1970/-"), so the whole price is captured.
  t = t.replaceAllMapped(
    RegExp(r'(\d[\d ,]{0,10}\d)\s*/\s*-'),
    (m) => '${m[1]!.replaceAll(RegExp(r'[ ,]'), '')}/-',
  );
  return t;
}

/// Scan [text] for any price match using [kPriceRegexes]. Returns the smallest
/// numeric value (wholesale heuristic) plus the raw matched substring.
(int?, String?) parsePrice(String text) {
  if (text.isEmpty) return (null, null);
  final repaired = _repairDigits(text);
  final candidates = <({int value, String raw})>[];
  for (final pattern in kPriceRegexes) {
    final re = RegExp(pattern, caseSensitive: false);
    for (final m in re.allMatches(repaired)) {
      final group = m.group(1);
      if (group == null) continue;
      final v = int.tryParse(group);
      if (v == null) continue;
      if (v < 80 || v > 100000) continue;
      candidates.add((value: v, raw: m.group(0) ?? group));
    }
  }
  if (candidates.isEmpty) return (null, null);
  candidates.sort((a, b) => kPickSmallestPrice
      ? a.value.compareTo(b.value)
      : b.value.compareTo(a.value));
  final pick = candidates.first;
  return (pick.value, pick.raw);
}
