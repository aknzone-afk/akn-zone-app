import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

/// One precomputed OCR record from `assets/seed/seed_manifest.json`.
class SeedEntry {
  final String id; // Drive file id
  final String filename;
  final String folder;
  final String? designNumber;
  final String? fabricName;
  final int? price;
  final String? priceText;
  final String ocrText;

  /// Earliest date this design is known to have existed on Drive (its "New to
  /// Old" date can't be later, even if Drive's Last modified was bumped).
  final DateTime? firstSeen;

  /// Drive version the price was verified against (null = unverified).
  final String? driveVersion;

  const SeedEntry({
    required this.id,
    required this.filename,
    required this.folder,
    required this.designNumber,
    required this.fabricName,
    required this.price,
    required this.priceText,
    required this.ocrText,
    this.firstSeen,
    this.driveVersion,
  });

  factory SeedEntry.fromJson(Map<String, dynamic> j) => SeedEntry(
        id: j['id'] as String,
        filename: (j['filename'] ?? '') as String,
        folder: (j['folder'] ?? '') as String,
        designNumber: j['design_number'] as String?,
        fabricName: j['fabric_name'] as String?,
        price: (j['price'] as num?)?.toInt(),
        priceText: j['price_text'] as String?,
        ocrText: (j['ocr_text'] ?? '') as String,
        firstSeen: DateTime.tryParse((j['first_seen'] ?? '') as String),
        driveVersion: j['drive_version'] as String?,
      );
}

/// Loads the bundled seed manifest exactly once per app session. Provides
/// O(1) lookup by Drive file ID so the CatalogService can fast-path photos
/// without redoing OCR on every customer's phone.
class SeedLoader {
  Map<String, SeedEntry>? _index;
  Future<Map<String, SeedEntry>>? _loading;

  /// Identifies this bundled manifest (its generation time); '' if missing.
  String generatedAt = '';

  Future<Map<String, SeedEntry>> load() {
    if (_index != null) return Future.value(_index!);
    return _loading ??= _doLoad();
  }

  Future<Map<String, SeedEntry>> _doLoad() async {
    try {
      final raw = await rootBundle.loadString('assets/seed/seed_manifest.json');
      final json = jsonDecode(raw) as Map<String, dynamic>;
      generatedAt = (json['generated_at'] ?? '') as String;
      final entries = (json['entries'] as List<dynamic>? ?? const [])
          .map((e) => SeedEntry.fromJson(e as Map<String, dynamic>));
      final index = <String, SeedEntry>{
        for (final e in entries) e.id: e,
      };
      _index = index;
      return index;
    } catch (_) {
      // Missing or malformed seed is non-fatal — we just fall back to ML Kit.
      _index = const {};
      return const {};
    }
  }
}
