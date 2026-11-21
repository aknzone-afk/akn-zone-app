// Owner 21-Nov-2026: "Design not in app?" on the order screen.
//  - the customer types a design number, sees its photo from the shop's full photo set, selects colours / pieces
//    on it like any design and it joins the order WITH its photo;
//  - no photo of that design: design number / quantity / colour choice are typed, and travel with the order —
//    saved on the phone and written at the top of the shop's details message.
import 'package:catalog_app/models/order.dart';
import 'package:catalog_app/models/photo.dart';
import 'package:catalog_app/services/drive_urls.dart';
import 'package:catalog_app/services/old_designs.dart';
import 'package:catalog_app/services/order_service.dart';
import 'package:catalog_app/services/photo_freshness.dart' show photoFetchOrder;
import 'package:flutter_test/flutter_test.dart';

Order _order(List<OldDesign> old, {List<OrderItem> more = const []}) => Order(
      number: 'AKN-2111-1100-ABC',
      createdAt: DateTime(2026, 11, 21, 11),
      items: [
        OrderItem(photoId: 'p1', designNumber: 'LOTUS (4)', folder: 'PRINTED SAREES', price: 300, qty: 100),
        ...more,
      ],
      customer: CustomerDetails(kind: 'old', billName: 'B B SYNTHETICS', bookingPlace: 'SURAT', mobile: '9999900001'),
      note: 'Send fast',
      oldDesigns: old,
    );

const _index = '{"updated":"2026-11-21","p":{"1444":["aaaaaaaa","bbbbbbbb"],"N254":["5641ee46"],"t-77":["cccccccc","NOT A HASH"],"X1":[]}}';

// the same, with each design's modelling (12 X 18) photo named under "m"
const _indexM = '{"p":{"1444":["aaaaaaaa","bbbbbbbb","dddddddd"],"N254":["5641ee46"],"5021":["eeeeeeee"],"3549":["ffffffff","abcdef01"]},'
    '"m":{"1444":"aaaaaaaa","5021":"eeeeeeee","n-254":"00000000","9999":"12345678"}}';

void main() {
  group('typed rows (no photo)', () {
    test('old designs survive saving and loading the order', () {
      final o = _order(const [
        OldDesign(design: '5521', qty: '2 set', colours: 'Red, green'),
        OldDesign(design: 'T10027', qty: '10 pcs'),
      ]);
      final back = Order.fromJson(Map<String, dynamic>.from(o.toJson()));
      expect(back.oldDesigns.length, 2);
      expect(back.oldDesigns[0].design, '5521');
      expect(back.oldDesigns[0].qty, '2 set');
      expect(back.oldDesigns[0].colours, 'Red, green');
      expect(back.oldDesigns[1].colours, '');
    });

    test('an order saved by an older app (no such field) still loads', () {
      final j = Map<String, dynamic>.from(_order(const []).toJson());
      expect(j.containsKey('old'), isFalse);
      expect(Order.fromJson(j).oldDesigns, isEmpty);
    });

    test('the shop\'s details message lists them at the top, with quantity and colours', () async {
      final text = await OrderService.detailsText(_order(const [
        OldDesign(design: '5521', qty: '2 set', colours: 'Red, green'),
        OldDesign(design: 'T10027', qty: '10 pcs'),
      ]));
      final lines = text.split('\n');
      expect(lines[0], contains('1 design'));
      expect(lines[1], contains('NOT IN APP, no photo'));
      expect(lines[1], contains('2 weeks'));
      expect(lines[1], contains('(2)'));
      expect(lines[2], '• D.No 5521 — 2 set — colours: Red, green');
      expect(lines[3], '• D.No T10027 — 10 pcs');
      expect(text, contains('Bill Name:'));
      expect(text, contains('Send fast'));
    });

    test('a quantity stored as a number still loads (as text)', () {
      final j = Map<String, dynamic>.from(_order(const []).toJson());
      j['old'] = [
        {'d': '77', 'q': 12}
      ];
      expect(Order.fromJson(j).oldDesigns.single.qty, '12');
    });

    test('no old designs = the message is exactly as before', () async {
      final text = await OrderService.detailsText(_order(const []));
      expect(text, isNot(contains('NOT IN APP')));
    });

    test('odd characters typed by the customer cannot break the message', () async {
      final text = await OrderService.detailsText(_order(const [OldDesign(design: '<b>55', qty: '3 <u>', colours: 'a & b <i>')]));
      expect(text, isNot(contains('<i>')));
      expect(text, isNot(contains('<u>')));
      expect(text, contains('&lt;b&gt;55'));
    });
  });

  group('photo from the shop\'s full photo set', () {
    test('what the customer types becomes a design key', () {
      expect(OldDesigns.keyOf(' n-254 (a) '), 'N254A');
      expect(OldDesigns.keyOf('1444'), '1444');
      expect(OldDesigns.keyOf('  '), '');
      expect(OldDesigns.baseOf('1444A'), '1444');
      expect(OldDesigns.baseOf('n254 rani'), 'N254');
      expect(OldDesigns.baseOf('T10033'), 'T10033');
      expect(OldDesigns.baseOf('LOTUS'), 'LOTUS');
    });

    test('a catalogue photo\'s name gives its design (copy number / colour word dropped)', () {
      expect(OldDesigns.catalogKey('7242 (3)'), '7242');
      expect(OldDesigns.catalogKey('T56 (10)'), 'T56');
      expect(OldDesigns.catalogKey('7391 (A)'), '7391');
      expect(OldDesigns.catalogKey('5257 LIGHT MATCHING'), '5257');
      expect(OldDesigns.catalogKey('LOTUS (4)'), 'LOTUS');
      expect(OldDesigns.catalogKey('T10033'), 'T10033');
    });

    test('the index is read; bad entries are dropped, never a crash', () {
      final idx = OldDesigns.parseIndex(_index);
      expect(idx['1444'], ['aaaaaaaa', 'bbbbbbbb']);
      expect(idx['N254'], ['5641ee46']);
      expect(idx['T77'], ['cccccccc']); // key normalised, the non-hash dropped
      expect(idx['X1'], isEmpty);
      expect(OldDesigns.parseIndex('{"p":[1,2]}'), isEmpty);
      expect(OldDesigns.parseIndex('[]'), isEmpty);
    });

    test('a typed number finds its photos — exact design first, then without the copy letter', () {
      final idx = OldDesigns.parseIndex(_index);
      expect(OldDesigns.idsIn(idx, '1444'), ['rb-1444_aaaaaaaa', 'rb-1444_bbbbbbbb']);
      expect(OldDesigns.idsIn(idx, 'n 254'), ['rb-N254_5641ee46']);
      expect(OldDesigns.idsIn(idx, '1444 b'), ['rb-1444_aaaaaaaa', 'rb-1444_bbbbbbbb']);
      expect(OldDesigns.idsIn(idx, '9999'), isEmpty);
      expect(OldDesigns.idsIn(idx, 'X1'), isEmpty); // listed, but no photo
      expect(OldDesigns.idsIn(idx, ''), isEmpty);
    });

    test('the modelling (12 X 18) photo is never offered — only the other photos', () {
      final idx = OldDesigns.parseIndex(_indexM);
      expect(OldDesigns.idsIn(idx, '1444'), ['rb-1444_bbbbbbbb', 'rb-1444_dddddddd']);
      expect(OldDesigns.idsIn(idx, '3549'), ['rb-3549_ffffffff', 'rb-3549_abcdef01']); // no modelling photo: all of them
      expect(OldDesigns.idsIn(idx, 'N254'), ['rb-N254_5641ee46']); // "m" names another photo: nothing dropped
      expect(OldDesigns.idsIn(idx, '5021'), isEmpty); // ONLY a modelling photo = no photo (quantity is typed)
    });

    test('an index without "m" (an older file) still reads', () {
      expect(OldDesigns.idsIn(OldDesigns.parseIndex(_index), '1444'), ['rb-1444_aaaaaaaa', 'rb-1444_bbbbbbbb']);
      expect(OldDesigns.parseIndex('{"p":{"77":["aaaaaaaa"]},"m":[1,2]}')['77'], ['aaaaaaaa']);
    });

    test('a picked photo is a normal photo: design number, no price, its own folder name', () {
      final ph = OldDesigns.photoOf('rb-N254_5641ee46');
      expect(ph.id, 'rb-N254_5641ee46');
      expect(ph.designNumber, 'N254');
      expect(ph.price, isNull);
      expect(ph.folder, kOldDesignFolder);
      expect(ph.ocrState, OcrState.done);
      expect(OldDesigns.designOf('rb-1444_aaaaaaaa'), '1444');
    });

    test('its picture address is the photo set\'s, with a second host behind it; Drive ids are untouched', () {
      const id = 'rb-N254_5641ee46';
      expect(DriveUrls.isOld(id), isTrue);
      expect(DriveUrls.isOld('1AbCdEfGhIjKlMnOpQrStUv'), isFalse);
      const url = 'https://aknzone-afk.github.io/rate-bolo/p/N254_5641ee46.jpg';
      expect(DriveUrls.thumbnail(id, width: 600), url);
      expect(DriveUrls.thumbnail(id, width: 1600), url);
      expect(DriveUrls.content(id), url);
      expect(photoFetchOrder(url),
          [url, 'https://raw.githubusercontent.com/aknzone-afk/rate-bolo/main/p/N254_5641ee46.jpg', url]);
      expect(DriveUrls.thumbnail('1AbCdEfGhIjKlMnOpQrStUv', width: 600),
          'https://drive.google.com/thumbnail?id=1AbCdEfGhIjKlMnOpQrStUv&sz=w600');
    });

    test('the shop is told which designs of the order are not in the app', () async {
      final text = await OrderService.detailsText(_order(const [], more: [
        OrderItem(photoId: 'rb-N254_5641ee46', designNumber: 'N254', folder: kOldDesignFolder, price: null, qty: 12, pick: '12 pcs'),
        OrderItem(photoId: 'rb-3549_aaaaaaaa', designNumber: '3549', folder: kOldDesignFolder, price: null, qty: 6),
      ]));
      final line = text.split('\n').firstWhere((l) => l.contains('NOT IN APP'));
      expect(line, contains('2 designs NOT IN APP'));
      expect(line, contains('2 weeks'));
      expect(line, contains('D.No N254, D.No 3549'));
      expect(text, isNot(contains('no photo')));
    });

    test('an order with only catalogue designs says nothing about it', () async {
      expect(await OrderService.detailsText(_order(const [])), isNot(contains('NOT IN APP')));
    });
  });
}
