import 'package:catalog_app/services/order_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Indian mobile', () {
    expect(OrderService.normalizeIndianMobile('98250 12345'), '9825012345');
    expect(OrderService.normalizeIndianMobile('+91 98250-12345'), '9825012345');
    expect(OrderService.normalizeIndianMobile('09825012345'), '9825012345');
    expect(OrderService.normalizeIndianMobile('5825012345'), isNull);
    expect(OrderService.normalizeIndianMobile('982501234'), isNull);
    expect(OrderService.validateMobile('', india: true), isNotNull);
  });
  test('Foreign mobile', () {
    expect(OrderService.normalizeForeignMobile('+971 50 123 4567'), '971501234567');
    expect(OrderService.normalizeForeignMobile('123'), isNull);
  });
  test('Pincode', () {
    expect(OrderService.validatePincode('395002', india: true), isNull);
    expect(OrderService.validatePincode('095002', india: true), isNotNull);
    expect(OrderService.validatePincode('SW1A 1AA', india: false), isNull);
  });
  test('Tax id', () {
    expect(OrderService.taxIdKind('24ABIFR2700F1ZM'), 'GST');
    expect(OrderService.taxIdKind('abifr2700f'), 'PAN');
    expect(OrderService.taxIdKind('2345 6789 0123'), 'Aadhaar');
    expect(OrderService.taxIdKind('12345')!.startsWith('!'), isTrue);
    expect(OrderService.taxIdKind(''), isNull);
  });
  test('Place match + rupees', () {
    const info = PincodeInfo('Surat', 'Gujarat', {'surat', 'varachha road', 'surat city'});
    expect(OrderService.placeMatches('SURAT', info), isTrue);
    expect(OrderService.placeMatches('Lucknow', info), isFalse);
    expect(OrderService.formatRupees(749000), '₹7,49,000');
    expect(OrderService.formatRupees(535), '₹535');
  });
  test('Minimum order 30,000', () {
    var v = OrderService.valueCheck([(price: 535, qty: 10, sure: true), (price: 900, qty: 5, sure: true)]);
    expect(v.below, isTrue); // 9,850
    v = OrderService.valueCheck([(price: 1000, qty: 30, sure: true)]);
    expect(v.below, isFalse);
    v = OrderService.valueCheck([(price: 535, qty: 1, sure: true), (price: null, qty: 3, sure: true)]);
    expect(v.below, isTrue);
    v = OrderService.valueCheck([(price: 535, qty: 1, sure: false)]);
    expect(v.below, isTrue); // strict: unpriced counts ₹0
  });
}
