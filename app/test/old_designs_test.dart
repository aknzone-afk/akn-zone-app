// Owner 21-Nov-2026: "Designs not in app" — typed design number / quantity / colour choice
// travel with the order: saved on the phone, and written at the top of the shop's details message.
import 'package:catalog_app/models/order.dart';
import 'package:catalog_app/services/order_service.dart';
import 'package:flutter_test/flutter_test.dart';

Order _order(List<OldDesign> old) => Order(
      number: 'AKN-2111-1100-ABC',
      createdAt: DateTime(2026, 11, 21, 11),
      items: [OrderItem(photoId: 'p1', designNumber: 'LOTUS (4)', folder: 'PRINTED SAREES', price: 300, qty: 100)],
      customer: CustomerDetails(kind: 'old', billName: 'B B SYNTHETICS', bookingPlace: 'SURAT', mobile: '9999900001'),
      note: 'Send fast',
      oldDesigns: old,
    );

void main() {
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

  test('the shop\'s details message lists them at the top, with pieces and colours', () async {
    final text = await OrderService.detailsText(_order(const [
      OldDesign(design: '5521', qty: '2 set', colours: 'Red, green'),
      OldDesign(design: 'T10027', qty: '10 pcs'),
    ]));
    final lines = text.split('\n');
    expect(lines[0], contains('1 design'));
    expect(lines[1], contains('DESIGNS NOT IN APP'));
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
}

