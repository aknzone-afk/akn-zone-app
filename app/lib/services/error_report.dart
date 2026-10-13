import 'dart:io';

import 'package:dio/dio.dart';

/// Sends an app error to the shop's cloud (bbapp_errors) so it can be fixed
/// without asking the customer. Never throws; at most 20 reports per run.
int _sent = 0;
final _dio = Dio();

void reportAppError(String error, StackTrace? stack) {
  if (_sent >= 20) return;
  _sent++;
  final lines = (stack?.toString() ?? '').split('\n').take(25).join('\n');
  _dio
      .post<dynamic>('https://asia-south1-akn-chat-a7dd8.cloudfunctions.net/appError',
          data: {
            'error': error.length > 1500 ? error.substring(0, 1500) : error,
            'stack': lines,
            'platform': Platform.operatingSystem,
            'os': Platform.operatingSystemVersion,
          },
          options: Options(headers: {'x-app-key': 'akn-zone-app-v3'}))
      .catchError((_) => Response<dynamic>(requestOptions: RequestOptions()));
}
