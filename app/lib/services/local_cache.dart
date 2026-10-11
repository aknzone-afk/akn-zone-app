import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../models/photo.dart';

/// SQLite-backed cache for the scraped catalog + OCR results + favorites.
class LocalCache {
  Database? _db;
  Completer<Database>? _opening;

  Future<Database> _open() async {
    if (_db != null) return _db!;
    if (_opening != null) return _opening!.future;
    _opening = Completer<Database>();
    try {
      final dir = await getApplicationSupportDirectory();
      // Bumped to v12 — first launch now seeds the catalog from the bundled
      // manifest (instant, offline) behind the loading screen, and a few
      // OCR-misread prices were corrected in that manifest. A fresh DB makes the
      // updated build re-seed so those corrections + the new first-run flow take
      // effect immediately. Favorites/cart migrate from the newest prior db.
      final newPath = p.join(dir.path, 'catalog_v14.db');
      final candidates = [
        'catalog_v13.db',
        'catalog_v12.db',
        'catalog_v11.db',
        'catalog_v10.db',
        'catalog_v9.db',
        'catalog_v8.db',
        'catalog_v7.db',
        'catalog_v6.db',
        'catalog_v5.db',
        'catalog_v4.db',
        'catalog_v3.db',
        'catalog_v2.db',
      ];
      String? oldPath;
      for (final c in candidates) {
        final cp = p.join(dir.path, c);
        if (File(cp).existsSync()) {
          oldPath = cp;
          break;
        }
      }
      final isFirstOpen = !File(newPath).existsSync();
      final db = await openDatabase(
        newPath,
        version: 2,
        onUpgrade: (db, oldVersion, newVersion) async {
          if (oldVersion < 2) {
            // Columns may already exist if an older build downgraded the DB
            // after this one ran; their versions are then untrustworthy.
            final cols = {
              for (final r in await db.rawQuery('PRAGMA table_info(photos)'))
                r['name'],
            };
            if (!cols.contains('drive_version')) {
              await db
                  .execute('ALTER TABLE photos ADD COLUMN drive_version TEXT');
            }
            if (!cols.contains('drive_modified')) {
              await db.execute(
                  'ALTER TABLE photos ADD COLUMN drive_modified INTEGER');
            }
            await db.execute('UPDATE photos SET drive_version = NULL');
          }
        },
        onCreate: (db, v) async {
          await db.execute('''
            CREATE TABLE photos (
              id TEXT PRIMARY KEY,
              filename TEXT NOT NULL,
              folder TEXT NOT NULL DEFAULT '',
              design_number TEXT,
              fabric_name TEXT,
              price INTEGER,
              price_text TEXT,
              ocr_text TEXT NOT NULL DEFAULT '',
              ocr_state TEXT NOT NULL DEFAULT 'pending',
              last_seen INTEGER NOT NULL DEFAULT 0,
              drive_version TEXT,
              drive_modified INTEGER
            )
          ''');
          await db.execute('CREATE INDEX idx_photos_folder ON photos(folder)');
          await db.execute('CREATE INDEX idx_photos_price ON photos(price)');
          await db.execute(
              'CREATE INDEX idx_photos_design ON photos(design_number)');
          await db.execute(
              'CREATE INDEX idx_photos_ocr_state ON photos(ocr_state)');
          await db.execute('''
            CREATE TABLE favorites (
              photo_id TEXT PRIMARY KEY,
              added_at INTEGER NOT NULL
            )
          ''');
          await db.execute('''
            CREATE TABLE folders (
              path TEXT PRIMARY KEY
            )
          ''');
        },
      );
      // One-shot migration: copy favorites from the newest prior db.
      if (isFirstOpen && oldPath != null) {
        try {
          final oldDb = await openDatabase(oldPath, readOnly: true);
          final rows = await oldDb.query('favorites');
          await oldDb.close();
          if (rows.isNotEmpty) {
            final batch = db.batch();
            for (final r in rows) {
              batch.insert('favorites', r,
                  conflictAlgorithm: ConflictAlgorithm.replace);
            }
            await batch.commit(noResult: true);
          }
        } catch (_) {/* old db missing / unreadable — ignore */}
      }
      _db = db;
      _opening!.complete(db);
      return db;
    } catch (e, st) {
      _opening!.completeError(e, st);
      _opening = null;
      rethrow;
    }
  }

  // -------- Photos --------

  Future<bool> hasPhotos() async {
    final db = await _open();
    final r = await db.rawQuery('SELECT COUNT(*) AS c FROM photos');
    return (r.first['c'] as int? ?? 0) > 0;
  }

  Future<int> photoCount() async {
    final db = await _open();
    final r = await db.rawQuery('SELECT COUNT(*) AS c FROM photos');
    return (r.first['c'] as int? ?? 0);
  }

  Future<List<Photo>> allPhotos() async {
    final db = await _open();
    final rows = await db.query('photos', orderBy: 'folder ASC, filename ASC');
    return rows.map(Photo.fromSqliteRow).toList(growable: false);
  }

  Future<List<Photo>> photosPendingOcr({int limit = 200}) async {
    final db = await _open();
    final rows = await db.query('photos',
        where: 'ocr_state = ?', whereArgs: ['pending'], limit: limit);
    return rows.map(Photo.fromSqliteRow).toList(growable: false);
  }

  /// Applies prices verified against specific Drive file versions. A row takes
  /// the verified price only if its own price came from that same version (or
  /// its version was never recorded), so a newer read is never overwritten.
  Future<void> applyVerifiedPrices(
      Iterable<({String id, int price, String priceText, String version})>
          verified) async {
    final db = await _open();
    await db.transaction((txn) async {
      final batch = txn.batch();
      for (final v in verified) {
        batch.rawUpdate(
          "UPDATE photos SET price = ?, price_text = ?, ocr_text = ?, "
          "ocr_state = 'done', drive_version = ? "
          "WHERE id = ? AND (drive_version IS NULL OR drive_version = ?) "
          "AND NOT (ocr_text = '' AND price IS NOT NULL)",
          [v.price, v.priceText, v.priceText, v.version, v.id, v.version],
        );
      }
      await batch.commit(noResult: true);
    });
  }

  Future<bool> isPending(String photoId) async {
    final db = await _open();
    final rows = await db.query('photos',
        columns: ['ocr_state'],
        where: 'id = ?',
        whereArgs: [photoId],
        limit: 1);
    return rows.isNotEmpty && rows.first['ocr_state'] == OcrState.pending.name;
  }

  Future<List<String>> allFolders() async {
    final db = await _open();
    final rows = await db.query('folders', orderBy: 'path ASC');
    return rows.map((r) => r['path'] as String).toList(growable: false);
  }

  /// Upsert scrape results.
  ///
  /// OCR-merge policy:
  ///   - If the new Photo arrives with `ocrState == done` (meaning the seed
  ///     manifest provided OCR data), OVERWRITE the existing row's OCR fields.
  ///     The seed is authoritative on every cold sync.
  ///   - If the new Photo has `ocrState == pending`, preserve any previously-
  ///     computed OCR result so a per-device ML Kit pass isn't wasted.
  ///
  /// When [deleteMissing] is true (the default), photos absent from
  /// [seenPhotos] are removed from the cache — that's the normal "the scrape
  /// is authoritative" path. When the scrape is partial (some folder fetches
  /// flaked) the caller passes `deleteMissing: false` so we additively upsert
  /// what we did see and keep the rest of the cache intact, rather than
  /// nuking real photos because Drive returned an empty page.
  Future<({int added, int removed})> upsertScrape({
    required List<Photo> seenPhotos,
    required Set<String> folders,
    required int scrapeTimestamp,
    bool deleteMissing = true,
  }) async {
    final db = await _open();
    int added = 0;
    int removed = 0;
    await db.transaction((txn) async {
      final existing = await txn.query('photos', columns: ['id']);
      final existingIds = existing.map((r) => r['id'] as String).toSet();
      final seenIds = seenPhotos.map((p) => p.id).toSet();

      final batch = txn.batch();
      for (final p in seenPhotos) {
        if (existingIds.contains(p.id)) {
          final patch = <String, Object?>{
            'filename': p.filename,
            'folder': p.folder,
            'design_number': p.designNumber,
          };
          if (p.ocrState == OcrState.done) {
            // Seed (or any authoritative OCR source) wins — overwrite the row.
            patch['fabric_name'] = p.fabricName;
            patch['price'] = p.price;
            patch['price_text'] = p.priceText;
            patch['ocr_text'] = p.ocrText;
            patch['ocr_state'] = OcrState.done.name;
          }
          batch.update('photos', patch, where: 'id = ?', whereArgs: [p.id]);
          // "New to Old" date: keep the first one seen. Drive bumps "Last
          // modified" whenever a photo is replaced, which must not make an old
          // design look new.
          if (p.driveModified != null) {
            batch.rawUpdate(
              'UPDATE photos SET drive_modified = COALESCE(drive_modified, ?) '
              'WHERE id = ?',
              [p.driveModified, p.id],
            );
          }
          if (p.ocrState != OcrState.done) {
            // Its old folder's name priced it and its current folder doesn't:
            // read the price off the image instead.
            batch.rawUpdate(
              "UPDATE photos SET price = NULL, price_text = NULL, "
              "ocr_state = 'pending' "
              "WHERE id = ? AND ocr_text = '' AND price IS NOT NULL",
              [p.id],
            );
          }
        } else {
          batch.insert('photos', p.toSqliteRow(),
              conflictAlgorithm: ConflictAlgorithm.replace);
          added++;
        }
      }

      if (deleteMissing) {
        final missing = existingIds.difference(seenIds);
        for (final id in missing) {
          batch.delete('photos', where: 'id = ?', whereArgs: [id]);
          removed++;
        }

        await txn.delete('folders');
        for (final f in folders) {
          batch.insert('folders', {'path': f},
              conflictAlgorithm: ConflictAlgorithm.replace);
        }
      } else {
        // Partial scrape: just add any newly-discovered folder paths on top
        // of the existing folder set instead of wiping it.
        for (final f in folders) {
          batch.insert('folders', {'path': f},
              conflictAlgorithm: ConflictAlgorithm.ignore);
        }
      }

      await batch.commit(noResult: true);
    });
    return (added: added, removed: removed);
  }

  /// [driveVersion] is the version of the file the price was read from; it is
  /// only written when known so an unknown never erases a known one.
  Future<void> saveOcr({
    required String photoId,
    required String? fabricName,
    required int? price,
    required String? priceText,
    required String ocrText,
    required OcrState state,
    String? driveVersion,
  }) async {
    final db = await _open();
    await db.update(
      'photos',
      {
        'fabric_name': fabricName,
        'price': price,
        'price_text': priceText,
        'ocr_text': ocrText,
        'ocr_state': state.name,
        if (driveVersion != null) 'drive_version': driveVersion,
      },
      where: 'id = ?',
      whereArgs: [photoId],
    );
  }

  /// Records freshly-checked Drive versions. Rows in [needsReread] are also
  /// flipped back to `pending` so the OCR runner re-reads their price.
  Future<void> saveDriveVersions(
    Map<String, String> versions, {
    Set<String> needsReread = const {},
  }) async {
    if (versions.isEmpty) return;
    final db = await _open();
    await db.transaction((txn) async {
      final batch = txn.batch();
      versions.forEach((id, v) {
        // Skip rows already at this version: a read that finished after the
        // caller's snapshot must not be undone.
        batch.update(
          'photos',
          {
            'drive_version': v,
            if (needsReread.contains(id)) 'ocr_state': OcrState.pending.name,
          },
          where: 'id = ? AND (drive_version IS NULL OR drive_version <> ?)',
          whereArgs: [id, v],
        );
      });
      await batch.commit(noResult: true);
    });
  }

  // -------- Favorites --------

  Future<Set<String>> allFavoriteIds() async {
    final db = await _open();
    final rows = await db.query('favorites', columns: ['photo_id']);
    return rows.map((r) => r['photo_id'] as String).toSet();
  }

  Future<void> setFavorite(String photoId, bool starred) async {
    final db = await _open();
    if (starred) {
      await db.insert(
        'favorites',
        {
          'photo_id': photoId,
          'added_at': DateTime.now().millisecondsSinceEpoch
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    } else {
      await db.delete('favorites', where: 'photo_id = ?', whereArgs: [photoId]);
    }
  }

  Future<void> clearFavorites() async {
    final db = await _open();
    await db.delete('favorites');
  }
}
