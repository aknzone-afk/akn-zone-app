import 'package:flutter/foundation.dart';

import '../config.dart';
import '../services/drive_urls.dart';

/// OCR processing state for a single photo.
enum OcrState { pending, done, failed }

/// One photo entry mirroring a Drive file.
@immutable
class Photo {
  /// Stable ID == Drive file ID.
  final String id;

  /// Display filename.
  final String filename;

  /// POSIX-relative folder path inside the catalog ("" = root).
  final String folder;

  /// Extracted from filename (e.g. "D12345").
  final String? designNumber;

  /// Extracted from OCR text. Null until OCR runs.
  final String? fabricName;

  /// Extracted from OCR text. Null until OCR runs.
  final int? price;

  /// Raw matched price string (e.g. "RS 1095/-").
  final String? priceText;

  /// Raw OCR output (for debugging + future re-parsing).
  final String ocrText;

  /// State machine for background OCR.
  final OcrState ocrState;

  /// First time this device saw the photo in a Drive scrape (seconds since
  /// epoch). Not bumped by later scrapes.
  final int lastSeen;

  /// Drive's file version (its ETag, e.g. "v7"). It changes whenever the file
  /// is replaced, so a mismatch means the price must be re-read. Null until
  /// the current file has been checked.
  final String? driveVersion;

  /// Drive "Last modified" time (ms since epoch), from the folder listing.
  final int? driveModified;

  const Photo({
    required this.id,
    required this.filename,
    required this.folder,
    required this.designNumber,
    required this.fabricName,
    required this.price,
    required this.priceText,
    required this.ocrText,
    required this.ocrState,
    required this.lastSeen,
    this.driveVersion,
    this.driveModified,
  });

  /// True when the price comes from the folder name rather than the image.
  bool get priceFromFolder => ocrText.isEmpty && price != null;

  /// "New to Old": newest Drive date first (unknown dates last); within the
  /// same date, higher design numbers first, since those are the newer designs.
  static int compareNewestFirst(Photo a, Photo b) {
    final am = a.driveModified;
    final bm = b.driveModified;
    if (am != bm) {
      if (am == null) return 1;
      if (bm == null) return -1;
      return bm.compareTo(am);
    }
    final byNumber = _designNumberValue(b).compareTo(_designNumberValue(a));
    if (byNumber != 0) return byNumber;
    return b.filename.toLowerCase().compareTo(a.filename.toLowerCase());
  }

  static final _digits = RegExp(r'\d{1,9}');

  static int _designNumberValue(Photo p) {
    final m = _digits.firstMatch(p.designNumber ?? p.filename);
    return m == null ? -1 : int.parse(m.group(0)!);
  }

  /// Top-level folder name (first path segment).
  String get topFolder {
    if (folder.isEmpty) return '';
    final i = folder.indexOf('/');
    return i == -1 ? folder : folder.substring(0, i);
  }

  String thumbUrl({int width = kThumbnailWidth}) =>
      DriveUrls.thumbnail(id, width: width);

  String detailUrl({int width = kDetailImageWidth}) =>
      DriveUrls.thumbnail(id, width: width);

  Photo copyWith({
    String? fabricName,
    int? price,
    String? priceText,
    String? ocrText,
    OcrState? ocrState,
    int? lastSeen,
    String? driveVersion,
    int? driveModified,
  }) {
    return Photo(
      id: id,
      filename: filename,
      folder: folder,
      designNumber: designNumber,
      fabricName: fabricName ?? this.fabricName,
      price: price ?? this.price,
      priceText: priceText ?? this.priceText,
      ocrText: ocrText ?? this.ocrText,
      ocrState: ocrState ?? this.ocrState,
      lastSeen: lastSeen ?? this.lastSeen,
      driveVersion: driveVersion ?? this.driveVersion,
      driveModified: driveModified ?? this.driveModified,
    );
  }

  Map<String, dynamic> toSqliteRow() => {
        'id': id,
        'filename': filename,
        'folder': folder,
        'design_number': designNumber,
        'fabric_name': fabricName,
        'price': price,
        'price_text': priceText,
        'ocr_text': ocrText,
        'ocr_state': ocrState.name,
        'last_seen': lastSeen,
        'drive_version': driveVersion,
        'drive_modified': driveModified,
      };

  factory Photo.fromSqliteRow(Map<String, dynamic> row) => Photo(
        id: row['id'] as String,
        filename: row['filename'] as String,
        folder: (row['folder'] ?? '') as String,
        designNumber: row['design_number'] as String?,
        fabricName: row['fabric_name'] as String?,
        price: (row['price'] as num?)?.toInt(),
        priceText: row['price_text'] as String?,
        ocrText: (row['ocr_text'] ?? '') as String,
        ocrState: _stateFrom(row['ocr_state'] as String?),
        lastSeen: (row['last_seen'] as int?) ?? 0,
        driveVersion: row['drive_version'] as String?,
        driveModified: row['drive_modified'] as int?,
      );

  static OcrState _stateFrom(String? s) {
    switch (s) {
      case 'done':
        return OcrState.done;
      case 'failed':
        return OcrState.failed;
      default:
        return OcrState.pending;
    }
  }
}
