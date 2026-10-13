/// Owner 13-Oct: the shop's own HDFC BharatQR with the AMOUNT written into it,
/// so the customer only scans and presses Pay (₹0 — no payment gateway). A pay
/// LINK to this merchant UPI id is refused by PhonePe/GPay; a scanned QR is not.
/// Same merchant, same terminal (TID 82227366) → the payment still lands in the
/// HDFC payout report the morning bank check reads.
class UpiQr {
  /// Decoded from the shop's printed Vyapar QR (tags 00-62, CRC 63 removed).
  static const _base =
      '000201010211021644038482227366020415522024082227366061661000308222736630825HDFC00000015020012006240326460010A0000005240128vyapar.173947529358@hdfcbank27420010A0000005240124STQD198553417813311772225204565153033565802IN5914B B SYNTHETICS6005SURAT610639500262400524STQD19855341781331177222070882227366';

  /// EMV payload with tag 54 = [rupees] and "dynamic" point of initiation.
  static String withAmount(num rupees) {
    final tags = <MapEntry<String, String>>[];
    var i = 0;
    while (i + 4 <= _base.length) {
      final id = _base.substring(i, i + 2);
      final n = int.parse(_base.substring(i + 2, i + 4));
      tags.add(MapEntry(id, _base.substring(i + 4, i + 4 + n)));
      i += 4 + n;
    }
    final amount = rupees.toStringAsFixed(2);
    final out = <MapEntry<String, String>>[];
    for (final t in tags) {
      if (t.key == '54') continue;
      out.add(t.key == '01' ? const MapEntry('01', '12') : t);
      if (t.key == '53') out.add(MapEntry('54', amount)); // amount right after currency
    }
    final b = StringBuffer();
    for (final t in out) {
      b
        ..write(t.key)
        ..write(t.value.length.toString().padLeft(2, '0'))
        ..write(t.value);
    }
    b.write('6304');
    return '$b${_crc(b.toString())}';
  }

  /// CRC-16/CCITT-FALSE, as EMV QR requires (checked against the printed QR).
  static String _crc(String s) {
    var c = 0xFFFF;
    for (final ch in s.codeUnits) {
      c ^= ch << 8;
      for (var k = 0; k < 8; k++) {
        c = (c & 0x8000) != 0 ? ((c << 1) ^ 0x1021) & 0xFFFF : (c << 1) & 0xFFFF;
      }
    }
    return c.toRadixString(16).toUpperCase().padLeft(4, '0');
  }
}
