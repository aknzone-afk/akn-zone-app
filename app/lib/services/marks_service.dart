import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show mapEquals;
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/photo.dart';
import '../providers/providers.dart';
import 'edit_service.dart';

/// Pieces read from the customer's own marks on a photo (owner, 11-Oct-2026 —
/// same rules as the AKN Chat bot):
///   • cross / scribble on a saree  → that colour is NOT wanted
///   • tick / line / dot on sarees  → ONLY those sarees count
///   • a number written on a saree  → that many pieces of it
///   • no marks                     → every saree counts
/// The marked photo is read in the cloud (AKN Chat's reader, function
/// `readMarks`). Results are cached per photo + edit time, so a photo is read
/// once per change.
class MarksNotifier extends StateNotifier<Map<String, int>> {
  MarksNotifier(this._prefs, this._dio, this._edits) : super(const {}) {
    _restore();
  }

  final SharedPreferences _prefs;
  final Dio _dio;
  final EditService _edits;
  static const _kKey = 'marks_v1';
  static const _url =
      'https://asia-south1-akn-chat-a7dd8.cloudfunctions.net/readMarks';

  /// photoId → "editMillis:pieces"
  Map<String, String> _store = {};
  final Set<String> _busy = {};
  final Set<String> _failed = {};

  void _restore() {
    try {
      _store = Map<String, String>.from(
          jsonDecode(_prefs.getString(_kKey) ?? '{}') as Map);
    } catch (_) {
      _store = {};
    }
  }

  bool isReading(String id) => _busy.contains(id);

  /// Reads (or re-reads after a new edit) every marked photo in [photos].
  Future<void> ensure(Iterable<Photo> photos, Set<String> editedIds) async {
    final todo = <(Photo, int)>[];
    final next = Map<String, int>.from(state);
    for (final p in photos) {
      if (!editedIds.contains(p.id)) {
        next.remove(p.id);
        continue;
      }
      final f = await _edits.pathFor(p.id);
      if (!f.existsSync()) continue;
      final ms = f.statSync().modified.millisecondsSinceEpoch;
      final cached = _store[p.id];
      if (cached != null && cached.startsWith('$ms:')) {
        next[p.id] = int.parse(cached.split(':')[1]);
      } else if (!_busy.contains(p.id) && !_failed.contains('${p.id}@$ms')) {
        next.remove(p.id);
        todo.add((p, ms));
      }
    }
    // Only publish a real change — the cart calls this on every build.
    if (mounted && !mapEquals(next, state)) state = next;
    if (todo.isEmpty) return;
    for (final t in todo) {
      _busy.add(t.$1.id);
    }
    if (mounted) state = {...state}; // show "reading marks…"
    await Future.wait(todo.map((t) => _read(t.$1, t.$2)));
  }

  Future<void> _read(Photo p, int ms) async {
    try {
      var bytes = await _edits.read(p.id);
      if (bytes == null || bytes.isEmpty) return;
      final jpg = await FlutterImageCompress.compressWithList(bytes,
          quality: 85, minWidth: 1280, minHeight: 1280, format: CompressFormat.jpeg);
      if (jpg.isNotEmpty) bytes = jpg;
      final res = await _dio.post<dynamic>(
        _url,
        data: {'image': base64Encode(bytes)},
        options: Options(
          headers: {'x-app-key': 'akn-zone-app-v3'},
          contentType: Headers.jsonContentType,
          sendTimeout: const Duration(seconds: 60),
          receiveTimeout: const Duration(seconds: 120),
        ),
      );
      final d = res.data is String ? jsonDecode(res.data as String) : res.data;
      final n = (d is Map && d['ok'] == true) ? (d['pieces'] as num?)?.toInt() : null;
      if (n != null && n >= 0) {
        _store[p.id] = '$ms:$n';
        await _prefs.setString(_kKey, jsonEncode(_store));
        if (mounted) state = {...state, p.id: n};
      } else {
        _failed.add('${p.id}@$ms');
      }
    } catch (_) {
      _failed.add('${p.id}@$ms');
    } finally {
      _busy.remove(p.id);
      if (mounted) state = {...state};
    }
  }
}

final marksProvider = StateNotifierProvider<MarksNotifier, Map<String, int>>(
  (ref) => MarksNotifier(ref.watch(sharedPreferencesProvider),
      ref.watch(dioProvider), ref.watch(editServiceProvider)),
);
