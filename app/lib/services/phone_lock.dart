import 'dart:convert';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// PHONE LOCK (owner, 11-Oct-2026): one phone may order with at most 2 mobile
/// numbers. The phone's id lives in the iOS Keychain / Android secure storage,
/// so deleting and reinstalling the app on iPhone keeps it. The list of
/// numbers per phone is kept in the cloud (phoneLock function) so it can't be
/// wiped from the phone. The shop frees a number with "/reset 98…" in the
/// orders group.
class PhoneLock {
  static const _store = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );
  static const _kId = 'akn_phone_id_v1';
  static String? _cached;

  static Future<String> phoneId() async {
    if (_cached != null) return _cached!;
    String? id;
    try {
      id = await _store.read(key: _kId);
    } catch (_) {}
    if (id == null || id.isEmpty) {
      final r = Random.secure();
      id = List.generate(16, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
      try {
        await _store.write(key: _kId, value: id);
      } catch (_) {}
    }
    return _cached = id;
  }

  /// allowed=false → the 3rd number on this phone. A network problem never
  /// blocks an order (returns allowed with no warnings).
  static Future<({bool allowed, int index, String? first, bool newPhone, String phone, List<String> mobiles})>
      check(Dio dio, String mobile, {bool peek = false}) async {
    final id = await phoneId();
    try {
      final res = await dio.post<dynamic>(
        'https://asia-south1-akn-chat-a7dd8.cloudfunctions.net/phoneLock',
        data: {'device': id, 'mobile': mobile, if (peek) 'peek': true},
        options: Options(
            headers: {'x-app-key': 'akn-zone-app-v3'},
            contentType: Headers.jsonContentType,
            receiveTimeout: const Duration(seconds: 15)),
      );
      final d = res.data is String ? jsonDecode(res.data as String) : res.data;
      if (d is Map && d['ok'] == true) {
        return (
          allowed: d['allowed'] == true,
          index: (d['index'] as num?)?.toInt() ?? 1,
          first: d['first'] as String?,
          newPhone: d['newPhone'] == true,
          phone: '${d['phone'] ?? id.substring(id.length - 4).toUpperCase()}',
          // The numbers this phone is already linked to (when blocked).
          mobiles: [for (final x in (d['mobiles'] as List? ?? const [])) '$x'],
        );
      }
    } catch (_) {}
    return (allowed: true, index: 1, first: null, newPhone: false, phone: '', mobiles: const <String>[]);
  }
}
