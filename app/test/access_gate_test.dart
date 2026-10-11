import 'package:catalog_app/services/access_api.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('status lookup', () {
    test('approved customer gets in', () async {
      expect(await AccessApi.checkStatus('9999999999'), 'approved');
    });

    test('blocked customer is locked out', () async {
      expect(await AccessApi.checkStatus('7014465377'), 'removed');
    });

    test('unknown number is sent to registration', () async {
      expect(await AccessApi.checkStatus('1112223334'), 'not_found');
    });

    test('+91 and spacing variants resolve to the same customer', () async {
      for (final v in ['+91 99999 99999', '09999999999', '999-999-9999']) {
        expect(await AccessApi.checkStatus(v), 'approved', reason: v);
      }
    });

    test('secondary mobile column also matches', () async {
      expect(await AccessApi.checkStatus('8055799450'), 'approved');
    });
  });

  // When a shop re-registers, the owner leaves the old row as "(CLOSED)" +
  // blocked and adds a new approved row lower down. Stopping at the first
  // matching row made the stale blocked row win and permanently locked these
  // firms out of the catalog, with no way to recover from inside the app.
  group('duplicate rows — approval anywhere wins', () {
    const reRegistered = {
      '8923416408': 'K.P. CHAUDHARY SAREE EMPORIUM',
      '7032265109': 'KESARIYA SAREES NEW',
      '8866319772': 'KESARIYA SAREES NEW',
      '9424134692': 'VARSHA BAZAR',
      '9610772484': 'MANGLAM SAREES',
      '8294639239': 'NAGARMAL SHEONARAIN',
      '9770160094': 'RADHA NEW RAIPUR',
    };

    for (final e in reRegistered.entries) {
      test('${e.value} (${e.key}) is not blocked by its closed row', () async {
        expect(await AccessApi.checkStatus(e.key), 'approved');
      });
    }
  });

  group('sheet integrity', () {
    test('a sign-in page is rejected, not read as an empty customer list',
        () async {
      // HTML has balanced quotes so it parses as valid CSV. Left unchecked it
      // would look like "nobody is approved" and strand every customer on the
      // registration screen at once.
      final html = List.generate(
        400,
        (i) =>
            '<div class="g" id="row$i"><span>Sign in to continue</span></div>',
      ).join('\n');
      final rows = AccessApi.parseCsv(html);
      expect(
        () => AccessApi.assertIsUserListForTesting(rows),
        throwsA(isA<Exception>()),
      );
    });

    test('the real customer list passes the integrity check', () async {
      // Guards the check itself against being too strict — a false positive
      // here would lock out all ~1900 customers.
      expect(await AccessApi.checkStatus('9999999999'), 'approved');
    });
  });
}
