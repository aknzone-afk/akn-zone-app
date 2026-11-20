import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'phone_lock.dart';

/// Owner 17-Nov: never show an error just because one Google data centre is
/// busy. Every app cloud function runs in THREE regions, each with its own
/// 20-CPU cap: Delhi (asia-south2, first), Mumbai (asia-south1, where the
/// database lives) and Singapore (asia-southeast1, last resort - a little
/// farther away). When one refuses (429 / 5xx) or does not answer, the SAME
/// request goes to the next one.
const kCloudPrimary = 'asia-south2-akn-chat-a7dd8.cloudfunctions.net';
// 18-Nov: Singapore was never brought up (Google could not initialise it), so
// a call there only added a 404 and a delay. Delhi first, Mumbai as the backup.
const _kCloudChain = [
  'asia-south2-akn-chat-a7dd8.cloudfunctions.net',
  'asia-south1-akn-chat-a7dd8.cloudfunctions.net',
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

/// Owner 18-Nov: some mobile networks (Jio / Airtel) intermittently cannot
/// even look up aknzone-afk.github.io ("Failed host lookup") — the catalog,
/// prices and settings then never load and the app looks dead. The same files
/// are served by the statically.io CDN straight from the GitHub repo (jsDelivr refuses repos > 50 MB).
const kDataHost = 'aknzone-afk.github.io';
const kDataPrefix = '/akn-zone-data/';

/// 19-Nov: statically.io stalled on every file above a few KB (no body for 40 s)
/// and serves copies up to a day old. The copies now, in this order:
///  1. our own cloud address (`appData` — the host the app's API uses, so if the
///     app works at all it can reach it; reads GitHub server-side, 3 min fresh;
///     a busy Delhi falls over to Mumbai like every other call),
///  2. GitHub's raw host (a different name than github.io),
///  3. statically.io, last.
List<String> dataMirrorUrls(Uri u) {
  if (u.host != kDataHost || !u.path.startsWith(kDataPrefix)) return const [];
  final p = u.path.substring(kDataPrefix.length);
  return [
    if (p.startsWith('app/')) 'https://$kCloudPrimary/appData?p=${Uri.encodeQueryComponent(p)}',
    'https://raw.githubusercontent.com/aknzone-afk/akn-zone-data/main/$p',
    'https://cdn.statically.io/gh/aknzone-afk/akn-zone-data@main/$p',
  ];
}

/// The first (best) copy — for callers that try just one.
String? dataMirrorUrl(Uri u) {
  final all = dataMirrorUrls(u);
  return all.isEmpty ? null : all.first;
}

class RegionFallback extends Interceptor {
  RegionFallback(this._dio);
  final Dio _dio;

  /// 20-Nov (security): every call to our cloud says WHO is calling — the
  /// secret this phone got when its number was verified on WhatsApp
  /// (`x-dev-key`) and the phone's own id (`x-device`). The app key inside the
  /// APK is public; these two are what lets the server refuse a stranger who
  /// only knows a customer's mobile number. Never sent to any other host.
  @override
  Future<void> onRequest(RequestOptions options, RequestInterceptorHandler handler) async {
    if (_kCloudChain.contains(options.uri.host)) {
      try {
        final key = (await SharedPreferences.getInstance()).getString('account_devkey_v1') ?? '';
        if (key.length >= 16) options.headers['x-dev-key'] = key;
        options.headers['x-device'] = await PhoneLock.phoneId();
      } catch (_) {
        // the call still goes out; the server treats it as an older app
      }
    }
    handler.next(options);
  }

  @override
  Future<void> onError(DioException err, ErrorInterceptorHandler handler) async {
    final o = err.requestOptions;
    // GitHub Pages unreachable → the same file from the next copy, one after the other.
    final mirrors = dataMirrorUrls(o.uri);
    if (mirrors.isNotEmpty && o.extra['dataMirror'] != true && _retryable(err)) {
      for (final mirror in mirrors) {
        try {
          final r = await _dio.fetch<dynamic>(o.copyWith(
              path: mirror, baseUrl: '', queryParameters: const {}, extra: {...o.extra, 'dataMirror': true}));
          return handler.resolve(r);
        } catch (_) {
          // this copy failed too — try the next one
        }
      }
      return handler.next(err);
    }
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
