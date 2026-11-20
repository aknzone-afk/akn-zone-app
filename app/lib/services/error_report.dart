import 'dart:io';

import 'package:dio/dio.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'region_fallback.dart';

/// Sends an app error to the shop's cloud (bbapp_errors) so it can be fixed
/// without asking the customer. Never throws; at most 20 reports per run.
int _sent = 0;
String _ver = '';
final _dio = withRegionFallback(Dio());

/// Called once at start: learn the app version BEFORE the first report. Until
/// 3.1.55 the first report of every run went out without it (the version was
/// looked up only after the first error), which hid which build a crash was on.
void primeAppVersion() {
  if (_ver.isNotEmpty) return;
  // ignore: discarded_futures
  PackageInfo.fromPlatform().then((i) => _ver = '${i.version}+${i.buildNumber}').catchError((_) => _ver = '?');
}

void reportAppError(String error, StackTrace? stack) {
  if (_sent >= 20) return;
  _sent++;
  if (_ver.isEmpty) {
    // ignore: discarded_futures
    PackageInfo.fromPlatform().then((i) => _ver = '${i.version}+${i.buildNumber}').catchError((_) => _ver = '?');
  }
  final lines = (stack?.toString() ?? '').split('\n').take(25).join('\n');
  _dio
      .post<dynamic>('https://asia-south2-akn-chat-a7dd8.cloudfunctions.net/appError',
          data: {
            'error': error.length > 1500 ? error.substring(0, 1500) : error,
            'stack': lines,
            'platform': Platform.operatingSystem,
            'os': Platform.operatingSystemVersion,
            if (_ver.isNotEmpty) 'ver': _ver,
          },
          options: Options(headers: {'x-app-key': 'akn-zone-app-v3'}))
      .catchError((_) => Response<dynamic>(requestOptions: RequestOptions()));
}
