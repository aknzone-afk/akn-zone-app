import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:html/parser.dart' as html_parser;

import 'drive_urls.dart';

class DriveItem {
  final String id;
  final String name;
  final bool isFolder;

  /// Drive's "Last modified" value from the folder listing, if it parsed.
  final DateTime? modified;
  const DriveItem({
    required this.id,
    required this.name,
    required this.isFolder,
    this.modified,
  });

  @override
  String toString() => '${isFolder ? "FOLDER" : "FILE"} $name ($id)';
}

class DrivePhoto {
  /// Drive file ID.
  final String id;

  /// Filename (e.g. "D12345.jpg").
  final String name;

  /// POSIX-relative folder path from the catalog root ("" = root).
  final String folder;

  final DateTime? modified;

  const DrivePhoto({
    required this.id,
    required this.name,
    required this.folder,
    this.modified,
  });

  String get relPath => folder.isEmpty ? name : '$folder/$name';
}

const _kMonths = {
  'jan': 1,
  'feb': 2,
  'mar': 3,
  'apr': 4,
  'may': 5,
  'jun': 6,
  'jul': 7,
  'aug': 8,
  'sep': 9,
  'oct': 10,
  'nov': 11,
  'dec': 12,
};

/// Parses the en-US "Last modified" cell of Drive's embedded folder listing:
/// "12:30 am" (today), "Sep 13" (this year), "12/5/25" or "Dec 5, 2025"
/// (older years). Returns null for anything unrecognised.
DateTime? parseDriveModified(String raw, {DateTime? now}) {
  final t = raw.replaceAll(RegExp(r'[\s  ]+'), ' ').trim().toLowerCase();
  if (t.isEmpty) return null;
  final today = now ?? DateTime.now();

  final time = RegExp(r'^(\d{1,2}):(\d{2}) ?([ap])\.?m\.?$').firstMatch(t);
  if (time != null) {
    var h = int.parse(time.group(1)!) % 12;
    if (time.group(3) == 'p') h += 12;
    return DateTime(
        today.year, today.month, today.day, h, int.parse(time.group(2)!));
  }

  final monthDay =
      RegExp(r'^([a-z]{3})[a-z]*\.? (\d{1,2})(?:, (\d{4}))?$').firstMatch(t);
  if (monthDay != null) {
    final m = _kMonths[monthDay.group(1)];
    if (m == null) return null;
    final d = int.parse(monthDay.group(2)!);
    final y = monthDay.group(3);
    if (y != null) return DateTime(int.parse(y), m, d);
    final guess = DateTime(today.year, m, d);
    // Drive omits the year only for the current year; a date "in the future"
    // means the listing was rendered in a timezone already past New Year.
    return guess.isAfter(today.add(const Duration(days: 2)))
        ? DateTime(today.year - 1, m, d)
        : guess;
  }

  final numeric = RegExp(r'^(\d{1,2})/(\d{1,2})/(\d{2}|\d{4})$').firstMatch(t);
  if (numeric != null) {
    var y = int.parse(numeric.group(3)!);
    if (y < 100) y += 2000;
    return DateTime(
        y, int.parse(numeric.group(1)!), int.parse(numeric.group(2)!));
  }
  return null;
}

/// Recursively scrapes a public Drive folder. No auth.
class DriveScraper {
  final Dio _dio;
  final int maxConcurrentFolders;

  DriveScraper({Dio? dio, this.maxConcurrentFolders = 4})
      : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 20),
              receiveTimeout: const Duration(seconds: 30),
              headers: {'User-Agent': 'Mozilla/5.0 (Android) CatalogApp/1.0'},
            ));

  /// Returns *all* photos under [rootFolderId], recursively, plus a
  /// `complete` flag indicating whether every folder request succeeded. If
  /// any folder came back empty after the retry budget, `complete = false`
  /// and the caller should treat the photo list as a partial / suspect view
  /// and **not** apply destructive deletes against the cached catalog.
  ///
  /// [onProgress] receives `(scanned_folders, total_known_photos)` updates so
  /// the UI can show a live counter.
  /// [onPhotoDiscovered] is called the moment each individual photo is found —
  /// useful for the loading-screen collage that needs to show real designs as
  /// soon as possible.
  Future<({List<DrivePhoto> photos, bool complete})> walk(
    String rootFolderId, {
    void Function(int folders, int photos)? onProgress,
    void Function(DrivePhoto photo)? onPhotoDiscovered,
  }) async {
    final out = <DrivePhoto>[];
    var foldersScanned = 0;
    var failedFolders = 0;

    Future<void> visit(String folderId, String folderPath) async {
      final result = await _listFolder(folderId);
      if (!result.networkOk) failedFolders++;
      final items = result.items;
      foldersScanned++;
      for (final it in items) {
        if (!it.isFolder && _isImage(it.name)) {
          final dp = DrivePhoto(
              id: it.id,
              name: it.name,
              folder: folderPath,
              modified: it.modified);
          out.add(dp);
          onPhotoDiscovered?.call(dp);
        }
      }
      onProgress?.call(foldersScanned, out.length);

      final subs = items.where((i) => i.isFolder).toList();
      for (final sub in subs) {
        final subPath =
            folderPath.isEmpty ? sub.name : '$folderPath/${sub.name}';
        await visit(sub.id, subPath);
      }
    }

    await visit(rootFolderId, '');
    return (photos: out, complete: failedFolders == 0);
  }

  /// Lists a SINGLE Drive folder's items (non-recursive). Public wrapper around
  /// the internal lister so callers can do a fast, targeted refresh of one
  /// folder (e.g. the DAILY UPDATE folder opened from the 9 PM notification)
  /// without re-walking the whole catalog tree. Returns `[]` when the fetch
  /// failed, so callers never mistake a network error for an empty folder.
  Future<List<DriveItem>> listFolder(String folderId) async {
    final r = await _listFolder(folderId);
    return r.networkOk ? r.items : const <DriveItem>[];
  }

  /// Whether [filename] is one of the image types the catalog ingests.
  static bool isImageName(String filename) => _isImage(filename);

  /// Internal: returns whatever Drive's HTML listing parsed to, plus
  /// `networkOk` — true when at least one HTTP attempt returned 200. A
  /// `networkOk:true, items:[]` outcome means the folder is genuinely empty
  /// (e.g. the user removed every file from it), while
  /// `networkOk:false` means every attempt errored or timed out and we
  /// should treat the entire scrape as partial.
  Future<({List<DriveItem> items, bool networkOk})> _listFolder(
      String folderId) async {
    final url = DriveUrls.embeddedFolder(folderId);
    var networkOk = false;
    var bestItems = <DriveItem>[];
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        final res = await _dio.get<String>(
          url,
          options: Options(
            responseType: ResponseType.plain,
            headers: {
              // Desktop-Chrome UA returns the fullest folder listing.
              'User-Agent':
                  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36',
              'Accept':
                  'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
              'Accept-Language': 'en-US,en;q=0.9',
            },
          ),
        );
        networkOk = true;
        final items = parseEmbeddedFolderHtml(res.data ?? '');
        if (items.length > bestItems.length) bestItems = items;
        // Bail on the first non-empty parse; otherwise re-try in case Drive
        // raced its own JS rendering and served a sparse page.
        if (items.isNotEmpty) return (items: items, networkOk: true);
      } catch (_) {
        // swallow + retry
      }
      await Future<void>.delayed(Duration(milliseconds: 250 * (attempt + 1)));
    }
    return (items: bestItems, networkOk: networkOk);
  }

  static bool _isImage(String filename) {
    final lc = filename.toLowerCase();
    return lc.endsWith('.jpg') ||
        lc.endsWith('.jpeg') ||
        lc.endsWith('.png') ||
        lc.endsWith('.webp');
  }

  /// Visible for testing.
  static List<DriveItem> parseEmbeddedFolderHtml(String body) {
    final doc = html_parser.parse(body);
    final entries = doc.querySelectorAll('.flip-entry');
    final out = <DriveItem>[];
    for (final e in entries) {
      final rawId = e.id; // "entry-<file_id>"
      if (!rawId.startsWith('entry-')) continue;
      final id = rawId.substring(6);
      final titleEl = e.querySelector('.flip-entry-title');
      final name = titleEl?.text.trim() ?? '';
      // The folder icon class is on a div inside `.flip-entry-icon`.
      final iconDiv = e.querySelector('.flip-entry-icon > div');
      final iconClasses = iconDiv?.classes ?? const <String>{};
      final isFolder = iconClasses.any((c) => c.contains('folder'));
      if (id.isEmpty || name.isEmpty) continue;
      final modifiedText =
          e.querySelector('.flip-entry-last-modified')?.text ?? '';
      out.add(DriveItem(
        id: id,
        name: name,
        isFolder: isFolder,
        modified: parseDriveModified(modifiedText),
      ));
    }
    // Stable order: folders first, then files, both case-insensitive name asc.
    out.sort((a, b) {
      if (a.isFolder != b.isFolder) return a.isFolder ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return out;
  }

  /// Download bytes of any Drive file (anonymous, public link required).
  Future<Uint8List> downloadThumbnail(String fileId, {int width = 1024}) async {
    final url = DriveUrls.thumbnail(fileId, width: width);
    final res = await _dio.get<List<int>>(url,
        options: Options(responseType: ResponseType.bytes));
    return Uint8List.fromList(res.data ?? const []);
  }
}
