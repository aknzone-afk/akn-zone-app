import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Customer access control backed DIRECTLY by the Google Sheet.
///
/// The sheet is read through Google's CSV endpoint — no Apps Script, no server,
/// no API key. Columns (Users tab):
///   A Party Name | B City | C Mobile | D Mobile 2 | E Mobile 3 |
///   F Status | G Last Active | H Source | I Registered On
/// A customer is matched on ANY of their three mobile numbers.
///
/// Status → gate: approved = in; blocked/removed = locked out;
/// anything else = pending; no row = new (register).
class AccessApi {
  /// The customer list ("BB_Customers_final"). Must be shared as
  /// "Anyone with the link – Viewer" for the app to read it.
  static const String sheetId = ''; // login feature off — id kept out of the public code

  /// WhatsApp number new customers are handed off to for approval requests.
  static const String ownerWhatsApp = '917016638059';

  static const String _kCacheStatus = 'access_status';
  static const String _kCacheTs = 'access_status_ts';

  static bool get isConfigured => sheetId.isNotEmpty;

  static Uri _csv(String tab) => Uri.parse(
      'https://docs.google.com/spreadsheets/d/$sheetId/gviz/tq'
      '?tqx=out:csv&sheet=$tab&headers=0&t=${DateTime.now().millisecondsSinceEpoch}');

  static Future<String> _fetch(String tab) async {
    final res = await http.get(_csv(tab)).timeout(const Duration(seconds: 20));
    if (res.statusCode != 200) {
      throw Exception('Sheet fetch failed: ${res.statusCode}');
    }
    // http follows redirects silently, so a revoked share or a captive portal
    // lands here as HTTP 200 text/html. Refuse anything that is not CSV.
    final type = res.headers['content-type'] ?? '';
    if (type.contains('text/html')) {
      throw Exception('Sheet fetch returned HTML, not CSV');
    }
    return utf8.decode(res.bodyBytes);
  }

  /// Last 10 digits — tolerates +91, spaces, dashes, leading zeros.
  static String normalisePhone(String phone) {
    final d = phone.replaceAll(RegExp(r'\D'), '');
    return d.length > 10 ? d.substring(d.length - 10) : d;
  }

  /// Minimal RFC-4180 CSV parser: handles quoted fields containing commas,
  /// newlines and escaped quotes (the address column is full of commas).
  static List<List<String>> parseCsv(String input) {
    final rows = <List<String>>[];
    var row = <String>[];
    final field = StringBuffer();
    var inQuotes = false;
    for (var i = 0; i < input.length; i++) {
      final ch = input[i];
      if (inQuotes) {
        if (ch == '"') {
          if (i + 1 < input.length && input[i + 1] == '"') {
            field.write('"');
            i++;
          } else {
            inQuotes = false;
          }
        } else {
          field.write(ch);
        }
      } else {
        if (ch == '"') {
          inQuotes = true;
        } else if (ch == ',') {
          row.add(field.toString());
          field.clear();
        } else if (ch == '\n') {
          row.add(field.toString());
          field.clear();
          rows.add(row);
          row = <String>[];
        } else if (ch != '\r') {
          field.write(ch);
        }
      }
    }
    if (field.isNotEmpty || row.isNotEmpty) {
      row.add(field.toString());
      rows.add(row);
    }
    return rows;
  }

  /// Guards against a body that is HTTP 200 but is not the customer list —
  /// a Google sign-in page, a "You need access" interstitial, a captive-portal
  /// login. Those parse as perfectly valid CSV (HTML has balanced quotes), and
  /// treating one as an empty customer list would drop all ~1900 approved
  /// customers on the registration screen at once. Throwing instead lets the
  /// caller fall back to the last known-good decision.
  static void _assertIsUserList(List<List<String>> rows) {
    if (rows.length < 100) {
      throw Exception('Users sheet: only ${rows.length} rows');
    }
    var wide = 0;
    var withPhone = 0;
    for (final r in rows) {
      if (r.length < 6) continue;
      wide++;
      if (normalisePhone(r[2]).length == 10 ||
          normalisePhone(r[3]).length == 10 ||
          normalisePhone(r[4]).length == 10) {
        withPhone++;
      }
    }
    if (wide < rows.length * 0.8 || withPhone < 100) {
      throw Exception('Users sheet: $wide wide rows, $withPhone with a mobile');
    }
  }

  @visibleForTesting
  static void assertIsUserListForTesting(List<List<String>> rows) =>
      _assertIsUserList(rows);

  /// approved | pending | removed | not_found
  static Future<String> checkStatus(String phone) async {
    final target = normalisePhone(phone);
    if (target.isEmpty) return 'not_found';
    final rows = parseCsv(await _fetch('Users'));
    _assertIsUserList(rows);

    // A number legitimately appears on more than one row: when a shop
    // re-registers, the old row stays as "(CLOSED)" + blocked and a new
    // approved row is added lower down. So scan the WHOLE sheet and let an
    // approval anywhere win — stopping at the first match would lock out a
    // customer whose stale blocked row happens to sit higher up.
    var sawBlocked = false;
    var sawPending = false;
    for (final r in rows) {
      if (r.length < 6) continue;
      final matched = normalisePhone(r[2]) == target ||
          normalisePhone(r[3]) == target ||
          normalisePhone(r[4]) == target;
      if (!matched) continue;
      final status = r[5].toLowerCase().trim();
      if (status == 'approved') return 'approved';
      if (status == 'blocked' || status == 'removed') {
        sawBlocked = true;
      } else if (status != 'deleted') {
        sawPending = true;
      }
    }
    if (sawBlocked) return 'removed';
    if (sawPending) return 'pending';

    // Not in the Sheet — check the registration system.
    try {
      final regStatus = await registrationStatus(phone);
      if (regStatus == 'approved' ||
          regStatus == 'pending' ||
          regStatus == 'declined') {
        return regStatus == 'declined' ? 'removed' : regStatus;
      }
    } catch (_) {}

    return 'not_found';
  }

  /// Remembers the last decision so a flaky connection can't lock out a
  /// customer who was approved a moment ago.
  static Future<void> cacheStatus(String status) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kCacheStatus, status);
    await prefs.setInt(_kCacheTs, DateTime.now().millisecondsSinceEpoch);
  }

  /// How long an offline device may keep coasting on its last decision. Without
  /// a limit, "approved once" means approved forever: a customer who is later
  /// blocked only has to keep the app off docs.google.com to keep the catalog.
  /// Long enough that a genuine customer with patchy data is never inconvenienced.
  static const Duration _cacheTtl = Duration(days: 30);

  static Future<String?> cachedStatus() async {
    final prefs = await SharedPreferences.getInstance();
    final status = prefs.getString(_kCacheStatus);
    if (status == null) return null;
    final ts = prefs.getInt(_kCacheTs);
    if (ts == null) return status;
    final age = DateTime.now().millisecondsSinceEpoch - ts;
    // A stale 'approved' stops counting; a stale 'removed' still does, so that
    // letting the cache rot is never a way back in.
    if (age > _cacheTtl.inMilliseconds && status == 'approved') return null;
    return status;
  }

  /// The sheet is read-only from the app, so a new customer's request is handed
  /// to the shop over WhatsApp (pre-filled) instead of being written directly.
  /// The owner adds the row + sets `approved`, which the app picks up on the
  /// next open. Returns the deep link to launch.
  static Uri registrationWhatsAppLink({
    required String phone,
    required String firm,
    required String city,
  }) {
    final msg = 'NEW CATALOG ACCESS REQUEST\n'
        'Firm: $firm\n'
        'City: $city\n'
        'Mobile: ${normalisePhone(phone)}\n'
        'Please approve my access to the B.B Synthetics catalog.';
    return Uri.parse(
        'https://wa.me/$ownerWhatsApp?text=${Uri.encodeComponent(msg)}');
  }

  /// The same Apps Script that handles device binding also handles registration.
  static const String _scriptUrl =
      'https://script.google.com/macros/s/AKfycbyh1PRzRusVVJcn49x3RfkTXrLnFw-3PRNzFxmtHNsObEptaYYeZ6bS3dLsFpMqO8E/exec';

  /// Register a new customer. Data is stored server-side for owner approval.
  static Future<String> register({
    required String phone,
    required String firm,
    required String city,
  }) async {
    final res = await http
        .post(Uri.parse(_scriptUrl),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'action': 'register',
              'phone': normalisePhone(phone),
              'firm': firm,
              'city': city,
            }))
        .timeout(const Duration(seconds: 15));
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    return (body['status'] as String?) ?? 'error';
  }

  /// Check if a phone was registered and approved/declined via the script.
  static Future<String> registrationStatus(String phone) async {
    final res = await http
        .post(Uri.parse(_scriptUrl),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'action': 'reg_status',
              'phone': normalisePhone(phone),
            }))
        .timeout(const Duration(seconds: 15));
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    return (body['status'] as String?) ?? 'not_found';
  }

  static Future<Map<String, String>> getConfig() async {
    final rows = parseCsv(await _fetch('Config'));
    final cfg = <String, String>{};
    for (final r in rows) {
      if (r.length >= 2 && r[0].trim().isNotEmpty) {
        cfg[r[0].trim()] = r[1].trim();
      }
    }
    return cfg;
  }

  /// True if the installed version is BELOW the minimum in the Config tab.
  /// Fails open — never blocks the catalog because of a network error.
  static Future<bool> needsForceUpdate() async {
    try {
      final cfg = await getConfig();
      final info = await PackageInfo.fromPlatform();
      final key = Platform.isIOS ? 'minVersionIOS' : 'minVersionAndroid';
      return _isLower(info.version, cfg[key] ?? '0.0.0');
    } catch (_) {
      return false;
    }
  }

  static bool _isLower(String a, String b) {
    final pa = a.split('.').map((e) => int.tryParse(e) ?? 0).toList();
    final pb = b.split('.').map((e) => int.tryParse(e) ?? 0).toList();
    final n = pa.length > pb.length ? pa.length : pb.length;
    for (var i = 0; i < n; i++) {
      final x = i < pa.length ? pa[i] : 0;
      final y = i < pb.length ? pb[i] : 0;
      if (x < y) return true;
      if (x > y) return false;
    }
    return false;
  }
}
