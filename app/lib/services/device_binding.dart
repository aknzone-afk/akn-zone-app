import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class DeviceBinding {
  static const String _kDeviceId = 'device_binding_id';
  static const String _kBindingStatus = 'device_binding_status';

  /// Replace with the deployed Apps Script web app URL.
  static const String _scriptUrl =
      'https://script.google.com/macros/s/AKfycbyh1PRzRusVVJcn49x3RfkTXrLnFw-3PRNzFxmtHNsObEptaYYeZ6bS3dLsFpMqO8E/exec';

  static bool get isConfigured => _scriptUrl.isNotEmpty;

  static Future<String> _getDeviceId() async {
    final prefs = await SharedPreferences.getInstance();
    var id = prefs.getString(_kDeviceId);
    if (id == null || id.isEmpty) {
      id = _generateUuid();
      await prefs.setString(_kDeviceId, id);
    }
    return id;
  }

  static String _generateUuid() {
    final rng = Random.secure();
    final bytes = List<int>.generate(16, (_) => rng.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-'
        '${hex.substring(20)}';
  }

  static Future<Map<String, dynamic>> _post(Map<String, dynamic> body) async {
    final res = await http
        .post(
          Uri.parse(_scriptUrl),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 15));
    if (res.statusCode == 302 || res.statusCode == 301) {
      final redirect = res.headers['location'];
      if (redirect != null) {
        final res2 = await http
            .get(Uri.parse(redirect))
            .timeout(const Duration(seconds: 15));
        return jsonDecode(res2.body) as Map<String, dynamic>;
      }
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  /// Attempts to bind the current device to [phone].
  /// Returns 'bound' on success, 'conflict' if 2 other devices already hold it.
  static Future<String> bind(String phone) async {
    if (!isConfigured) return 'bound';
    final deviceId = await _getDeviceId();
    try {
      final result = await _post({
        'action': 'bind',
        'phone': phone,
        'deviceId': deviceId,
        'platform': Platform.isIOS ? 'ios' : 'android',
      });
      final status = (result['status'] as String?) ?? 'error';
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kBindingStatus, status);
      return status;
    } catch (_) {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(_kBindingStatus) ?? 'bound';
    }
  }

  /// Checks binding status without modifying anything.
  static Future<String> check(String phone) async {
    if (!isConfigured) return 'bound';
    final deviceId = await _getDeviceId();
    try {
      final result = await _post({
        'action': 'check',
        'phone': phone,
        'deviceId': deviceId,
      });
      return (result['status'] as String?) ?? 'error';
    } catch (_) {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(_kBindingStatus) ?? 'bound';
    }
  }

  /// Clears all bindings for [phone] (used by "Delete account").
  static Future<void> unbind(String phone) async {
    if (!isConfigured) return;
    try {
      await _post({'action': 'unbind', 'phone': phone});
    } catch (_) {
      // best-effort
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kBindingStatus);
  }

  /// Clears the local device ID and binding cache (full reset).
  static Future<void> clearLocal() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kDeviceId);
    await prefs.remove(_kBindingStatus);
  }
}
