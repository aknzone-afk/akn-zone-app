import 'package:dio/dio.dart';

/// Owner 17-Nov: never show an error just because one Google data centre is
/// busy. Every app cloud function runs in THREE regions, each with its own
/// 20-CPU cap: Delhi (asia-south2, first), Mumbai (asia-south1, where the
/// database lives) and Singapore (asia-southeast1, last resort - a little
/// farther away). When one refuses (429 / 5xx) or does not answer, the SAME
/// request goes to the next one.
const kCloudPrimary = 'asia-south2-akn-chat-a7dd8.cloudfunctions.net';
const _kCloudChain = [
  'asia-south2-akn-chat-a7dd8.cloudfunctions.net',
  'asia-south1-akn-chat-a7dd8.cloudfunctions.net',
  'asia-southeast1-akn-chat-a7dd8.cloudfunctions.net',
];

bool _retryable(DioException e) {
  final code = e.response?.statusCode;
  if (code != null) return code == 429 || code >= 500;
  return e.type == DioExceptionType.connectionTimeout ||
      e.type == DioExceptionType.receiveTimeout ||
      e.type == DioExceptionType.sendTimeout ||
      e.type == DioExceptionType.connectionError ||
      e.type == DioExceptionType.unknown;
}

class RegionFallback extends Interceptor {
  RegionFallback(this._dio);
  final Dio _dio;

  @override
  Future<void> onError(DioException err, ErrorInterceptorHandler handler) async {
    final o = err.requestOptions;
    final at = _kCloudChain.indexOf(o.uri.host);
    // a retry this interceptor itself sent: its loop below handles the chain
    if (o.extra['regionFallback'] == true) return handler.next(err);
    if (at < 0 || at == _kCloudChain.length - 1 || !_retryable(err)) return handler.next(err);
    var last = err;
    for (var i = at + 1; i < _kCloudChain.length; i++) {
      try {
        final retry = o.copyWith(
          path: o.uri.replace(host: _kCloudChain[i]).toString(),
          baseUrl: '',
          queryParameters: const {},
          extra: {...o.extra, 'regionFallback': true},
        );
        final r = await _dio.fetch<dynamic>(retry);
        return handler.resolve(r);
      } on DioException catch (e) {
        last = e;
        if (!_retryable(e)) break;
      } catch (_) {
        break;
      }
    }
    return handler.next(last);
  }
}

/// Adds the Delhi → Mumbai → Singapore fallback to [dio] (once) and returns it.
Dio withRegionFallback(Dio dio) {
  if (!dio.interceptors.any((i) => i is RegionFallback)) dio.interceptors.add(RegionFallback(dio));
  return dio;
}
