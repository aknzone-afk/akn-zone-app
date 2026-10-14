/// Owner 14-Oct: the sign-up checks GST / PAN / Aadhaar numbers by their shape
/// (no card photo). Same rules as the cloud's idValid().
library;

const _gstChars = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ';

String idNorm(String s) => s.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');

/// PAN: 5 letters (4th = holder type P/C/H/F/A/T/B/L/J/G), 4 digits, 1 letter.
bool panValid(String p) =>
    RegExp(r'^[A-Z]{3}[PCHFATBLJG][A-Z]\d{4}[A-Z]$').hasMatch(idNorm(p));

/// GST: state code (01-38, 97, 99) + PAN + entity no. + Z + check character.
bool gstValid(String raw) {
  final g = idNorm(raw);
  if (!RegExp(r'^\d{2}[A-Z]{3}[PCHFATBLJG][A-Z]\d{4}[A-Z][1-9A-Z]Z[0-9A-Z]$').hasMatch(g)) return false;
  final st = int.parse(g.substring(0, 2));
  if (!((st >= 1 && st <= 38) || st == 97 || st == 99)) return false;
  var sum = 0;
  for (var i = 0; i < 14; i++) {
    final v = _gstChars.indexOf(g[i]) * (i.isOdd ? 2 : 1);
    sum += v ~/ 36 + v % 36;
  }
  return _gstChars[(36 - sum % 36) % 36] == g[14];
}

const _vd = [
  [0, 1, 2, 3, 4, 5, 6, 7, 8, 9], [1, 2, 3, 4, 0, 6, 7, 8, 9, 5], [2, 3, 4, 0, 1, 7, 8, 9, 5, 6],
  [3, 4, 0, 1, 2, 8, 9, 5, 6, 7], [4, 0, 1, 2, 3, 9, 5, 6, 7, 8], [5, 9, 8, 7, 6, 0, 4, 3, 2, 1],
  [6, 5, 9, 8, 7, 1, 0, 4, 3, 2], [7, 6, 5, 9, 8, 2, 1, 0, 4, 3], [8, 7, 6, 5, 9, 3, 2, 1, 0, 4],
  [9, 8, 7, 6, 5, 4, 3, 2, 1, 0],
];
const _vp = [
  [0, 1, 2, 3, 4, 5, 6, 7, 8, 9], [1, 5, 7, 6, 2, 8, 3, 0, 9, 4], [5, 8, 0, 3, 7, 9, 6, 1, 4, 2],
  [8, 9, 1, 6, 0, 4, 3, 5, 2, 7], [9, 4, 5, 3, 1, 2, 6, 8, 7, 0], [4, 2, 8, 6, 5, 7, 3, 9, 0, 1],
  [2, 7, 9, 3, 8, 0, 6, 4, 1, 5], [7, 0, 4, 6, 9, 1, 3, 2, 5, 8],
];

/// Aadhaar: 12 digits, never starting with 0 or 1, Verhoeff check digit.
bool aadhaarValid(String raw) {
  final a = raw.replaceAll(RegExp(r'\D'), '');
  if (!RegExp(r'^[2-9]\d{11}$').hasMatch(a)) return false;
  var c = 0;
  final d = a.split('').reversed.toList();
  for (var i = 0; i < d.length; i++) {
    c = _vd[c][_vp[i % 8][int.parse(d[i])]];
  }
  return c == 0;
}

/// Live note under a box: null while empty, "✓ …" when right, "✗ …" otherwise.
String? idHint(String kind, String raw) {
  switch (kind) {
    case 'gst':
      final g = idNorm(raw);
      if (g.isEmpty) return null;
      if (g.length < 15) return '✗ GST has 15 characters — ${g.length} typed';
      if (g.length > 15) return '✗ GST has only 15 characters';
      if (!RegExp(r'^\d{2}').hasMatch(g)) return '✗ GST starts with 2 digits (state code, e.g. 24 for Gujarat)';
      return gstValid(g) ? '✓ GST number looks right' : '✗ This GST number is not valid — please check each character';
    case 'pan':
      final p = idNorm(raw);
      if (p.isEmpty) return null;
      if (p.length != 10) return '✗ PAN has 10 characters (e.g. ABCPE1234F) — ${p.length} typed';
      if (panValid(p)) return '✓ PAN number looks right';
      if (RegExp(r'^[A-Z]{5}\d{4}[A-Z]$').hasMatch(p)) {
        return '✗ The 4th letter of a PAN is P (person), F (firm), C (company), H, A, T, B, L, J or G — please check';
      }
      return '✗ PAN is 5 letters, 4 digits, 1 letter (e.g. ABCPE1234F)';
    case 'aadhaar':
      final a = raw.replaceAll(RegExp(r'\D'), '');
      if (a.isEmpty) return null;
      if (a.length != 12) return '✗ Aadhaar has 12 digits — ${a.length} typed';
      if (!RegExp(r'^[2-9]').hasMatch(a)) return '✗ Aadhaar never starts with 0 or 1';
      return aadhaarValid(a) ? '✓ Aadhaar number looks right' : '✗ This Aadhaar number is not valid — please check it';
  }
  return null;
}
