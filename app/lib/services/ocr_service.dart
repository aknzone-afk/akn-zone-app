/// Lightweight metadata parsers — design number from filename, price from
/// folder name. No image recognition; OCR was removed at the user's request.
library;

import 'package:path/path.dart' as p;

/// Returns the full filename without its extension as the design number.
/// Letters, numbers, punctuation, spaces — preserved exactly as in Drive.
String? extractDesignNumber(String filename) {
  final stem = p.basenameWithoutExtension(filename).trim();
  return stem.isEmpty ? null : stem;
}

/// Looks at a folder name (innermost segment of [folderPath] wins) and
/// returns a single price if the folder name encodes one unambiguously:
///
///   "P137 - Rs 275 NO PACKING"           -> 275
///   "LAHERIYA - Rs 285 NO PACKING"       -> 285
///   "VINTAGE PRINTS RS 510"              -> 510
///   "P143 - Rs 240"                      -> 240
///   "WORK UNDER Rs 700"                  -> null (it's an upper bound)
///   "WORK ABOVE Rs 1300"                 -> null (lower bound)
///   "WORK BETWEEN Rs 700 to 1300"        -> null (range)
///   "PRINTED - RS 170 ONWARDS"           -> null (open-ended)
///   "BANDHANI"                           -> null (no price hint)
({int? price, String? priceText}) extractFolderPrice(String folderPath) {
  if (folderPath.isEmpty) return (price: null, priceText: null);
  final segments = folderPath.split('/');
  final leaf = segments.last;
  final upper = leaf.toUpperCase();

  if (upper.contains('ONWARDS') ||
      upper.contains('BETWEEN') ||
      upper.contains('ABOVE') ||
      upper.contains('UNDER') ||
      upper.contains(' TO ')) {
    return (price: null, priceText: null);
  }

  final matches = RegExp(r'(?:RS|Rs)\.?\s*(\d{3,5})', caseSensitive: false)
      .allMatches(leaf)
      .toList();
  if (matches.length != 1) return (price: null, priceText: null);
  final v = int.tryParse(matches.first.group(1)!);
  if (v == null || v < 100 || v > 100000) {
    return (price: null, priceText: null);
  }
  return (price: v, priceText: matches.first.group(0));
}
