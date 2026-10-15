import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config.dart';

/// Owner 15-Oct: the catalogue's Drive folders come from app-config.json
/// ("catalog_folders": [{"id": "...", "name": "BANDHANI"}, ...]). When the
/// list is set, the app walks those folders instead of the old root folder —
/// so the old root can be switched off for old apps without touching this
/// one. Empty / unreachable list = the old root (kDriveFolderId), as before.
class CatalogRoots {
  static const _kPrefs = 'catalog_folders_v1';

  /// [] = use the old root folder.
  static Future<List<({String id, String name})>> load() async {
    SharedPreferences? prefs;
    try {
      prefs = await SharedPreferences.getInstance();
      final r = await Dio().get<String>(
          '$kAppConfigUrl?t=${DateTime.now().millisecondsSinceEpoch ~/ 300000}',
          options: Options(responseType: ResponseType.plain, receiveTimeout: const Duration(seconds: 10)));
      final j = jsonDecode(r.data ?? '{}') as Map<String, dynamic>;
      final list = _parse(j['catalog_folders']);
      await prefs.setString(_kPrefs, jsonEncode(j['catalog_folders'] ?? const []));
      return list;
    } catch (_) {
      // Offline: the last list we saw.
      try {
        return _parse(jsonDecode(prefs?.getString(_kPrefs) ?? '[]'));
      } catch (_) {
        return const [];
      }
    }
  }

  static List<({String id, String name})> _parse(Object? raw) => [
        for (final f in (raw is List ? raw : const []))
          if (f is Map && '${f['id'] ?? ''}'.isNotEmpty && '${f['name'] ?? ''}'.isNotEmpty)
            (id: '${f['id']}', name: '${f['name']}'),
      ];
}
