import 'package:dio/dio.dart';

/// Owner 17-Nov: never show an error just because one Google data centre is
/// busy. The app calls its cloud functions in Delhi (asia-south2); every one
/// of them also runs in Mumbai (asia-south1). Each region has its own 20-CPU
/// cap, so when Delhi refuses (429 / 5xx) or does not answer, the SAME request
/// is sent once to Mumbai.
const kCloudPrimary = 'asia-south2-akn-chat-a7dd8.cloudfunctions.net';
const kCloudFallback = 'asia-south1-akn-chat-a7dd8.cloudfunctions.net';

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
    if (o.uri.host != kCloudPrimary || o.extra['regionFallback'] == true || !_retryable(err)) {
      return handler.next(err);
    }
    try {
      final retry = o.copyWith(
        path: o.uri.replace(host: kCloudFallback).toString(),
        baseUrl: '',
        queryParameters: const {},
        extra: {...o.extra, 'regionFallback': true},
      );
      final r = await _dio.fetch<dynamic>(retry);
      return handler.resolve(r);
    } on DioException catch (e) {
      return handler.next(e);
    } catch (_) {
      return handler.next(err);
    }
  }
}

/// Adds the Delhi → Mumbai fallback to [dio] (once) and returns it.
Dio withRegionFallback(Dio dio) {
  if (!dio.interceptors.any((i) => i is RegionFallback)) dio.interceptors.add(RegionFallback(dio));
  return dio;
}
