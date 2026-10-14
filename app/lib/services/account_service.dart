import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/order.dart';
import 'chat_service.dart';
import 'order_service.dart';

/// Owner 14-Oct: customer ONBOARDING. Before the catalog every customer
/// verifies their mobile on WhatsApp ("AKN LOGIN <code>" to the shop's
/// number, the AKN Chat bot answers "✅ Verified"), then either claims their
/// Tally account (old customer) or fills the sign-up form and waits for the
/// shop's approval. The approved account is kept on the phone in
/// [kAccountKey] and re-checked in the background on every start / resume.
class AccountService {
  AccountService._();

  static const _cloud = 'https://asia-south1-akn-chat-a7dd8.cloudfunctions.net';
  static const _hdr = {'x-app-key': 'akn-zone-app-v3'};

  /// {mobile, india, status, kind, party, cust}
  static const kAccountKey = 'account_v1';

  /// The WhatsApp code being verified right now {code, mobile, country, at} —
  /// kept so the app can carry on polling after Android closed it while the
  /// customer was in WhatsApp.
  static const _kCodeKey = 'account_code_v1';

  /// The shop's WhatsApp number (AKN Chat bot).
  static const kShopWhatsApp = '917016638059';

  static final Dio dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 10),
    receiveTimeout: const Duration(seconds: 20),
    sendTimeout: const Duration(seconds: 60),
  ));

  // ───────────────────────── saved account ─────────────────────────

  static Map<String, dynamic>? saved(SharedPreferences p) {
    final s = p.getString(kAccountKey);
    if (s == null || s.isEmpty) return null;
    try {
      final d = jsonDecode(s);
      return d is Map ? Map<String, dynamic>.from(d) : null;
    } catch (_) {
      return null;
    }
  }

  static String status(SharedPreferences p) => '${saved(p)?['status'] ?? ''}';

  static Future<void> save(SharedPreferences p, Map<String, dynamic> a) =>
      p.setString(kAccountKey, jsonEncode(a));

  /// Log out / change number.
  static Future<void> clear(SharedPreferences p) async {
    await p.remove(kAccountKey);
    await p.remove(_kCodeKey);
  }

  /// The account's mobile as the cloud's customer key (for push).
  static String? mobileKey(SharedPreferences p) {
    final m = '${saved(p)?['mobile'] ?? ''}';
    return m.isEmpty ? null : ChatService.key(m);
  }

  // ───────────────────────── WhatsApp code ─────────────────────────

  static String newCode() {
    final r = Random.secure();
    return '${100000 + r.nextInt(900000)}';
  }

  static Uri whatsAppLink(String code) =>
      Uri.parse('https://wa.me/$kShopWhatsApp?text=AKN%20LOGIN%20$code');

  static Uri chatLink([String text = '']) => Uri.parse(
      'https://wa.me/$kShopWhatsApp${text.isEmpty ? '' : '?text=${Uri.encodeComponent(text)}'}');

  static Future<void> saveCode(SharedPreferences p,
          {required String code, required String mobile, required String country}) =>
      p.setString(
          _kCodeKey,
          jsonEncode({
            'code': code,
            'mobile': mobile,
            'country': country,
            'at': DateTime.now().millisecondsSinceEpoch,
          }));

  /// The code still being verified (null when none or older than 30 min).
  static ({String code, String mobile, String country, DateTime at})? savedCode(
      SharedPreferences p) {
    try {
      final s = p.getString(_kCodeKey);
      if (s == null) return null;
      final d = jsonDecode(s) as Map;
      final at = DateTime.fromMillisecondsSinceEpoch((d['at'] as num).toInt());
      if (DateTime.now().difference(at) > const Duration(minutes: 30)) return null;
      return (
        code: '${d['code']}',
        mobile: '${d['mobile'] ?? ''}',
        country: '${d['country'] ?? 'India'}',
        at: at,
      );
    } catch (_) {
      return null;
    }
  }

  static Future<void> clearCode(SharedPreferences p) => p.remove(_kCodeKey);

  // ───────────────────────── cloud calls ─────────────────────────

  /// POST to the cloud. Null = no internet / server trouble (never throws).
  static Future<Map<String, dynamic>?> _post(String fn, Map<String, dynamic> body,
      {int secs = 20}) async {
    try {
      final res = await dio.post<dynamic>('$_cloud/$fn',
          data: body,
          options: Options(
              headers: _hdr,
              contentType: Headers.jsonContentType,
              receiveTimeout: Duration(seconds: secs),
              validateStatus: (s) => s != null && s < 500));
      final d = res.data is String ? jsonDecode(res.data as String) : res.data;
      // Store review: keep this device's key — needed to delete the account.
      if (d is Map && '${d['devKey'] ?? ''}'.length >= 16) {
        final p = await SharedPreferences.getInstance();
        await p.setString(_kDevKey, '${d['devKey']}');
      }
      return d is Map ? Map<String, dynamic>.from(d) : null;
    } catch (_) {
      return null;
    }
  }

  static Future<Map<String, dynamic>?> verify(String code) =>
      _post('accountVerify', {'code': code});

  static Future<Map<String, dynamic>?> claim(String code, String party) =>
      _post('accountClaim', {'code': code, 'party': party});

  static Future<Map<String, dynamic>?> signup(String code, Map<String, dynamic> cust) =>
      _post('accountSignup', {'code': code, 'cust': cust}, secs: 60);

  /// Owner 14-Oct: customer abroad — no WhatsApp code; the cloud checks the
  /// network is outside India and the number is not Indian.
  static Future<Map<String, dynamic>?> signupAbroad(String mobile, Map<String, dynamic> cust) =>
      _post('accountSignup', {'abroad': true, 'mobile': mobile, 'cust': cust}, secs: 60);

  static const _kDevKey = 'account_devkey_v1';

  /// Owner 15-Oct: business-proof VIDEO -> one-time upload link, then PUT.
  /// Returns the stored path, or null (with [onProgress] 0..1 while sending).
  static Future<String?> uploadProofVideo(String code, String filePath,
      {void Function(double)? onProgress}) async {
    final d = await _post('proofUploadUrl', {'code': code});
    if (d == null || d['ok'] != true) return null;
    try {
      final f = File(filePath);
      final len = await f.length();
      final r = await Dio().put<dynamic>('${d['url']}',
          data: f.openRead(),
          options: Options(headers: {'Content-Type': 'video/mp4', 'Content-Length': len},
              sendTimeout: const Duration(minutes: 5), receiveTimeout: const Duration(minutes: 1)),
          onSendProgress: (a, b) => onProgress?.call(b > 0 ? a / b : 0));
      return (r.statusCode ?? 500) < 300 ? '${d['path']}' : null;
    } catch (_) {
      return null;
    }
  }

  /// Store reviewers (Google / Apple): fixed user ID + password -> demo account.
  static Future<Map<String, dynamic>?> demoLogin(String user, String pass) =>
      _post('accountDemo', {'user': user, 'pass': pass});

  /// "Delete my account" (App Store rule). True = deleted on the server.
  static Future<(bool, String?)> deleteAccount(SharedPreferences p) async {
    final m = '${saved(p)?['mobile'] ?? ''}';
    final d = await _post('accountDelete', {'mobile': m, 'devKey': p.getString(_kDevKey) ?? ''});
    if (d == null) return (false, 'No internet — please try again.');
    if (d['ok'] != true) return (false, '${d['error'] ?? 'Could not delete. Please try again.'}');
    await clear(p);
    await p.remove(_kDevKey);
    return (true, null);
  }

  static Future<Map<String, dynamic>?> checkStatus(String mobile) =>
      _post('accountStatus', {'mobile': mobile});

  // ───────────────────────── approval ─────────────────────────

  static String _s(Map? m, String k) => '${m?[k] ?? ''}'.trim();

  /// Approved → save the account and the order form's details, so the first
  /// order is pre-filled. kind 'existing' = an old Tally customer (no 10%
  /// token); 'new' stays 'new' (first order still pays the token).
  static Future<void> approve(SharedPreferences p, Map<String, dynamic> account) async {
    final a = {...account, 'status': 'approved'};
    await save(p, a);
    await clearCode(p);
    try {
      final cust = a['cust'] is Map ? Map<String, dynamic>.from(a['cust'] as Map) : <String, dynamic>{};
      final india = a['india'] != false;
      final raw = '${a['mobile'] ?? ''}';
      final mobile = india
          ? (OrderService.normalizeIndianMobile(raw) ?? raw)
          : (OrderService.normalizeForeignMobile(raw) ?? raw);
      String pick(List<String> keys) {
        for (final k in keys) {
          final v = _s(cust, k);
          if (v.isNotEmpty) return v;
        }
        return '';
      }

      var country = pick(['country']);
      if (country.isEmpty) country = india ? 'India' : 'Other';
      final party = _s(a, 'party');
      final c = CustomerDetails(
        kind: a['kind'] == 'existing' ? 'old' : 'new',
        country: country,
        billName: pick(['billName', 'name']).isNotEmpty ? pick(['billName', 'name']) : party,
        address: pick(['address']),
        bookingPlace: pick(['bookingPlace', 'dest', 'city']),
        pincode: pick(['pincode']),
        mobile: mobile,
        transport: pick(['transport']),
        taxId: pick(['taxId', 'gstin']),
      );
      await OrderService.saveCustomer(p, c);
    } catch (_) {}
  }
}
