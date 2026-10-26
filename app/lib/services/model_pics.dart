import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config.dart';

/// Owner 26-Oct: modelling photos (the 12 X 18 printing files, published by
/// the shop PC as app/model.json → {design no.: ["model/5938.jpg", …]}).
final modelPicsProvider = FutureProvider<Map<String, List<String>>>((ref) async {
  try {
    final r = await Dio().get<String>('$kDataBase/app/model.json?t=${DateTime.now().millisecondsSinceEpoch ~/ 1800000}',
        options: Options(responseType: ResponseType.plain, receiveTimeout: const Duration(seconds: 15)));
    final j = jsonDecode(r.data ?? '{}') as Map<String, dynamic>;
    final m = (j['m'] as Map?) ?? const {};
    return {
      for (final e in m.entries)
        '${e.key}'.toUpperCase(): [for (final x in (e.value as List? ?? const [])) '$kDataBase/app/$x'],
    };
  } catch (_) {
    return const {};
  }
});

/// Same key the shop uses: letters + digits of the design number ("N10022", "5938").
String modelKey(String? design) => (design ?? '').toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');

/// Owner 26-Oct: "1444 (A)" is design 1444 — the bracket is not part of the
/// number. Exact key first ("1444A", when such a photo exists), then the
/// number before the bracket / space / dash, then the leading digits.
List<String> modelPicsOf(Map<String, List<String>>? all, String? design) {
  if (all == null || all.isEmpty || design == null) return const [];
  final d = design.toUpperCase().trim();
  final keys = <String>{
    modelKey(d),
    modelKey(d.replaceAll(RegExp(r'\(.*?\)'), '')),
    modelKey(d.split(RegExp(r'[\s(\-/]')).first),
    RegExp(r'^[A-Z]*\d+').stringMatch(modelKey(d)) ?? '',
  };
  for (final k in keys) {
    final v = k.isEmpty ? null : all[k];
    if (v != null && v.isNotEmpty) return v;
  }
  return const [];
}
