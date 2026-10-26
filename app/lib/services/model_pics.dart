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
