import 'package:catalog_app/models/photo.dart';
import 'package:catalog_app/services/drive_scraper.dart';
import 'package:catalog_app/services/photo_freshness.dart';
import 'package:catalog_app/services/price_check.dart';
import 'package:flutter_test/flutter_test.dart';

Photo _photo(String name, {int? modified, int lastSeen = 0}) => Photo(
      id: name,
      filename: name,
      folder: 'F',
      designNumber: null,
      fabricName: null,
      price: null,
      priceText: null,
      ocrText: '',
      ocrState: OcrState.pending,
      lastSeen: lastSeen,
      driveModified: modified,
    );

void main() {
  final now = DateTime(2026, 9, 27, 15, 0);

  group('parseDriveModified', () {
    test('time only means today', () {
      expect(parseDriveModified('12:30 am', now: now),
          DateTime(2026, 9, 27, 0, 30));
      expect(parseDriveModified('4:05 PM', now: now),
          DateTime(2026, 9, 27, 16, 5));
      expect(parseDriveModified('12:10 pm', now: now),
          DateTime(2026, 9, 27, 12, 10));
    });

    test('month and day is this year', () {
      expect(parseDriveModified('Sep 13', now: now), DateTime(2026, 9, 13));
      expect(parseDriveModified('Jun 2', now: now), DateTime(2026, 6, 2));
    });

    test('a month-day later than today belongs to last year', () {
      expect(parseDriveModified('Dec 30', now: DateTime(2027, 1, 1)),
          DateTime(2026, 12, 30));
    });

    test('older years', () {
      expect(parseDriveModified('12/5/25', now: now), DateTime(2025, 12, 5));
      expect(
          parseDriveModified('Dec 5, 2025', now: now), DateTime(2025, 12, 5));
    });

    test('garbage is null', () {
      expect(parseDriveModified('', now: now), isNull);
      expect(parseDriveModified('—', now: now), isNull);
      expect(parseDriveModified('Foo 3', now: now), isNull);
    });
  });

  test('listing parser reads the Last modified column', () {
    const html = '<div class="flip-entries">'
        '<div class="flip-entry" id="entry-FILE1"><div class="flip-entry-info">'
        '<a href="https://drive.google.com/file/d/FILE1/view"><div class="flip-entry-visual">'
        '<div class="flip-entry-visual-card"><div class="flip-entry-thumb"><img src="x"/></div>'
        '</div></div><div class="flip-entry-title">5257 (A).jpg</div></a></div>'
        '<div class="flip-entry-last-modified"><div>Sep 13</div></div></div>'
        '<div class="flip-entry" id="entry-DIR1"><div class="flip-entry-info">'
        '<a href="https://drive.google.com/drive/folders/DIR1"><div class="flip-entry-visual">'
        '<div class="flip-entry-visual-card"><div class="flip-entry-icon">'
        '<div aria-label="Folder" class="drive-sprite-folder-grid-shared-icon"></div></div>'
        '</div></div><div class="flip-entry-title">BANDHANI</div></a></div>'
        '<div class="flip-entry-last-modified"><div>May 31</div></div></div>'
        '</div>';
    final items = DriveScraper.parseEmbeddedFolderHtml(html);
    final file = items.firstWhere((i) => i.id == 'FILE1');
    final dir = items.firstWhere((i) => i.id == 'DIR1');
    expect(file.isFolder, isFalse);
    expect(dir.isFolder, isTrue);
    expect(file.modified?.month, 9);
    expect(file.modified?.day, 13);
    expect(dir.modified?.month, 5);
  });

  test('New to Old: newest Drive date first, then higher design number', () {
    final sep13 = DateTime(2026, 9, 13).millisecondsSinceEpoch;
    final sep25 = DateTime(2026, 9, 25).millisecondsSinceEpoch;
    final list = [
      _photo('5257 (A).jpg', modified: sep13),
      _photo('unknown.jpg'),
      _photo('7018.jpg', modified: sep25, lastSeen: 999),
      _photo('7284.jpg', modified: sep25),
      _photo('P148 (7).jpg', modified: sep25),
    ]..sort(Photo.compareNewestFirst);
    expect(list.map((p) => p.filename).toList(), [
      '7284.jpg',
      '7018.jpg',
      'P148 (7).jpg',
      '5257 (A).jpg',
      'unknown.jpg'
    ]);
  });

  test('New to Old survives absurd digit runs in names', () {
    final list = [
      _photo('IMG_20260925123045678901234.jpg', modified: 1),
      _photo('0001.jpg', modified: 1),
    ]..sort(Photo.compareNewestFirst);
    expect(list.first.filename, 'IMG_20260925123045678901234.jpg');
  });

  test('price source', () {
    expect(_photo('a').priceFromFolder, isFalse);
    final folderPriced = Photo(
      id: 'x',
      filename: 'x',
      folder: 'SAREES Rs 700',
      designNumber: null,
      fabricName: null,
      price: 700,
      priceText: 'Rs 700',
      ocrText: '',
      ocrState: OcrState.done,
      lastSeen: 0,
    );
    expect(folderPriced.priceFromFolder, isTrue);
    expect(folderPriced.copyWith(ocrText: 'Rs 700/-').priceFromFolder, isFalse);
  });

  test('ETag normalisation', () {
    expect(normalizeEtag('"v7"'), 'v7');
    expect(normalizeEtag('W/"v10"'), 'v10');
    expect(normalizeEtag(' "va" '), 'va');
    expect(normalizeEtag('""'), isNull);
    expect(normalizeEtag(null), isNull);
  });

  test('Photo row round-trips version and modified date', () {
    final p = _photo('r.jpg', modified: 1234).copyWith(driveVersion: 'v7');
    final back = Photo.fromSqliteRow(p.toSqliteRow());
    expect(back.driveVersion, 'v7');
    expect(back.driveModified, 1234);
  });

  group('price label only shows a confirmed-current price', () {
    Photo read(int price, String version) => Photo(
          id: 'x', filename: '5257 (A).jpg', folder: 'F', designNumber: null,
          fabricName: null, price: price, priceText: 'Rs $price/-',
          ocrText: 'Rs $price/-', ocrState: OcrState.done, lastSeen: 0,
          driveVersion: version,
        );
    const round = PriceCheckState(trustCache: false);

    test('unconfirmed during a check round', () {
      expect(priceDisplayFor(read(985, 'v7'), round), PriceDisplay.checking);
    });
    test('confirmed: same version on Drive', () {
      const s = PriceCheckState(live: {'x': 'v7'}, trustCache: false);
      expect(priceDisplayFor(read(985, 'v7'), s), PriceDisplay.show);
      expect(priceLabel(read(985, 'v7'), PriceDisplay.show), '₹985');
    });
    test('replaced on Drive: old price hidden until re-read', () {
      const s = PriceCheckState(live: {'x': 'v8'}, trustCache: true);
      expect(priceDisplayFor(read(985, 'v7'), s), PriceDisplay.updating);
      expect(priceLabel(read(985, 'v7'), PriceDisplay.updating), '₹ ···');
      expect(priceDisplayFor(read(1010, 'v8'), s), PriceDisplay.show);
    });
    test('queued re-read hides the old price', () {
      final queued = read(985, 'v8').copyWith(ocrState: OcrState.pending);
      expect(priceDisplayFor(queued, const PriceCheckState()),
          PriceDisplay.updating);
    });
    test('offline / between rounds shows the stored price', () {
      expect(priceDisplayFor(read(985, 'v7'), const PriceCheckState()),
          PriceDisplay.show);
    });
    test('folder price always shows; no price shows nothing', () {
      final folder = Photo(
        id: 'f', filename: 'P148 (7).jpg', folder: 'P148 - Rs 265',
        designNumber: null, fabricName: null, price: 265, priceText: 'Rs 265',
        ocrText: '', ocrState: OcrState.done, lastSeen: 0,
      );
      expect(priceDisplayFor(folder, round), PriceDisplay.show);
      expect(priceDisplayFor(_photo('new.jpg'), round), PriceDisplay.none);
    });
  });
}
