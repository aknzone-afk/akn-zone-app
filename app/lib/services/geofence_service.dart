import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// IP-geolocation gate. On each cold start the app calls ipapi.co (no API key,
/// free for low volume) to read the device's approximate lat/long, compares
/// against Surat (21.1702° N, 72.8311° E), and blocks browsing if the result
/// is within [_radiusKm].
///
/// Notes:
/// - Result is cached for 24h to keep startup snappy and stay well under the
///   free tier's request budget.
/// - Network errors fail-open (allow) and *don't* cache, so a flaky connection
///   never permanently locks out a legitimate remote customer.
/// - A daily-rotating bypass PIN (today's day-of-month + "26", e.g. "1826" on
///   the 18th) overrides the gate for the rest of the calendar day, so the
///   shop can test in-store without having to spoof location.
class GeofenceService {
  static const double _suratLat = 21.1702;
  static const double _suratLng = 72.8311;
  static const double _radiusKm = 100;

  static const String _kCacheTsKey = 'geo_check_ts';
  static const String _kCacheAllowedKey = 'geo_check_allowed';
  static const String _kBypassDayKey = 'geo_bypass_day';
  static const String _kLifetimeBypassKey = 'geo_lifetime_bypass';
  static const String _kCacheCityKey = 'geo_check_city';
  static const String _kCacheRegionKey = 'geo_check_region';
  static const String _kCacheCountryKey = 'geo_check_country';
  static const String _kCacheIpKey = 'geo_check_ip';
  static const String _kCacheLatKey = 'geo_check_lat';
  static const String _kCacheLngKey = 'geo_check_lng';
  static const String _kCacheDistKey = 'geo_check_dist';
  static const String _kCacheSourceKey = 'geo_check_source';
  static const String _kCacheErrorKey = 'geo_check_error';
  static const Duration _cacheValidity = Duration(hours: 24);

  final Dio _dio;
  GeofenceService(this._dio);

  /// 24-hour PIN. Day part = (day-of-month × 2 + 3), zero-padded to 2 digits;
  /// year part is fixed at (26 × 2 + 10) = 62. So: "{day×2+3}62".
  ///   • 9th  → (9×2+3)=21  → "2162"
  ///   • 18th → (18×2+3)=39 → "3962"
  ///   • 31st → (31×2+3)=65 → "6562"
  static String todaysPin() {
    final now = DateTime.now();
    final dayPart = (now.day * 2 + 3).toString().padLeft(2, '0');
    return '${dayPart}62';
  }

  /// Lifetime PIN. Day part = (day × 2 + 3), month part = (month × 2 + 10), each
  /// zero-padded to 2 digits. So: "{day×2+3}{month×2+10}".
  ///   •  9 Jun → (9×2+3)=21,  (6×2+10)=22  → "2122"
  ///   • 18 May → (18×2+3)=39, (5×2+10)=20  → "3920"
  ///   • 31 Dec → (31×2+3)=65, (12×2+10)=34 → "6534"
  /// Rotates daily so an old code can't be reused, but once entered the
  /// bypass is permanent for this device.
  static String todaysLifetimePin() {
    final now = DateTime.now();
    final dayPart = (now.day * 2 + 3).toString().padLeft(2, '0');
    final monthPart = (now.month * 2 + 10).toString().padLeft(2, '0');
    return '$dayPart$monthPart';
  }

  /// "YYYY-MM-DD" — used as the cache key for the daily bypass.
  static String _todayKey() {
    final now = DateTime.now();
    final m = now.month.toString().padLeft(2, '0');
    final d = now.day.toString().padLeft(2, '0');
    return '${now.year}-$m-$d';
  }

  /// True if either the 24-hour bypass or the lifetime bypass is active.
  static bool isBypassActive(SharedPreferences prefs) {
    if (prefs.getBool(_kLifetimeBypassKey) == true) return true;
    final saved = prefs.getString(_kBypassDayKey);
    return saved != null && saved == _todayKey();
  }

  /// Validate [entered] against the day PIN OR the lifetime PIN.
  ///   • Returns `(true, lifetime: false)` for the daily PIN — bypass expires
  ///     at next midnight.
  ///   • Returns `(true, lifetime: true)` for the lifetime PIN — bypass is
  ///     permanent for this device.
  ///   • Returns `(false, lifetime: false)` for wrong codes.
  static Future<({bool ok, bool lifetime})> tryBypass(
      String entered, SharedPreferences prefs) async {
    final clean = entered.replaceAll(RegExp(r'[^0-9]'), '');
    if (clean == todaysLifetimePin()) {
      await prefs.setBool(_kLifetimeBypassKey, true);
      return (ok: true, lifetime: true);
    }
    if (clean == todaysPin()) {
      await prefs.setString(_kBypassDayKey, _todayKey());
      return (ok: true, lifetime: false);
    }
    return (ok: false, lifetime: false);
  }

  /// True ⇢ allow access. False ⇢ block (show lock screen).
  Future<bool> isAllowed(SharedPreferences prefs) async {
    // Bypass always wins.
    if (isBypassActive(prefs)) return true;

    // Cached IP-geo result (≤ 24h old).
    final ts = prefs.getInt(_kCacheTsKey);
    if (ts != null) {
      final cached = DateTime.fromMillisecondsSinceEpoch(ts);
      if (DateTime.now().difference(cached) < _cacheValidity) {
        return prefs.getBool(_kCacheAllowedKey) ?? true;
      }
    }

    // Fresh IP-geo lookup. Try multiple services in order — ipapi.co
    // occasionally rate-limits or returns HTML, so we don't rely on a single
    // provider.
    final errors = <String>[];
    for (final svc in _services) {
      try {
        final r = await _lookup(svc);
        if (r == null) {
          errors.add('${svc.name}: bad response');
          continue;
        }
        final dist = _haversineKm(r.lat, r.lng, _suratLat, _suratLng);
        final allowed = dist > _radiusKm;
        await prefs.setInt(_kCacheTsKey, DateTime.now().millisecondsSinceEpoch);
        await prefs.setBool(_kCacheAllowedKey, allowed);
        await prefs.setString(_kCacheCityKey, r.city);
        await prefs.setString(_kCacheRegionKey, r.region);
        await prefs.setString(_kCacheCountryKey, r.country);
        await prefs.setString(_kCacheIpKey, r.ip);
        await prefs.setDouble(_kCacheLatKey, r.lat);
        await prefs.setDouble(_kCacheLngKey, r.lng);
        await prefs.setDouble(_kCacheDistKey, dist);
        await prefs.setString(_kCacheSourceKey, svc.name);
        await prefs.setString(_kCacheErrorKey, '');
        return allowed;
      } catch (e) {
        errors.add('${svc.name}: $e');
      }
    }
    // Every service failed — fail-open, but remember why for the debug panel.
    await prefs.setString(_kCacheErrorKey, errors.join(' | '));
    return true;
  }

  static const List<_IpSvc> _services = [
    _IpSvc(name: 'ipapi.co', url: 'https://ipapi.co/json/'),
    _IpSvc(name: 'ipwho.is', url: 'https://ipwho.is/'),
    _IpSvc(name: 'ipinfo.io', url: 'https://ipinfo.io/json'),
  ];

  Future<_LookupResult?> _lookup(_IpSvc svc) async {
    final res = await _dio.get<dynamic>(
      svc.url,
      options: Options(
        responseType: ResponseType.json,
        receiveTimeout: const Duration(seconds: 10),
        sendTimeout: const Duration(seconds: 10),
        headers: const {
          'Accept': 'application/json',
          'User-Agent': 'CatalogApp/1.0 (Android)'
        },
      ),
    );
    final raw = res.data;
    if (raw is! Map) return null;
    return _parse(svc.name, raw);
  }

  _LookupResult? _parse(String svcName, Map raw) {
    switch (svcName) {
      case 'ipapi.co':
        final lat = (raw['latitude'] as num?)?.toDouble();
        final lng = (raw['longitude'] as num?)?.toDouble();
        if (lat == null || lng == null) return null;
        return _LookupResult(
          lat: lat,
          lng: lng,
          city: (raw['city'] as String?) ?? '',
          region: (raw['region'] as String?) ?? '',
          country: (raw['country_name'] as String?) ?? '',
          ip: (raw['ip'] as String?) ?? '',
        );
      case 'ipwho.is':
        // ipwho.is returns {success: true, latitude, longitude, ...}
        if (raw['success'] == false) return null;
        final lat = (raw['latitude'] as num?)?.toDouble();
        final lng = (raw['longitude'] as num?)?.toDouble();
        if (lat == null || lng == null) return null;
        return _LookupResult(
          lat: lat,
          lng: lng,
          city: (raw['city'] as String?) ?? '',
          region: (raw['region'] as String?) ?? '',
          country: (raw['country'] as String?) ?? '',
          ip: (raw['ip'] as String?) ?? '',
        );
      case 'ipinfo.io':
        // ipinfo.io returns {loc: "lat,lng", ...}
        final loc = raw['loc'] as String?;
        if (loc == null) return null;
        final parts = loc.split(',');
        if (parts.length != 2) return null;
        final lat = double.tryParse(parts[0]);
        final lng = double.tryParse(parts[1]);
        if (lat == null || lng == null) return null;
        return _LookupResult(
          lat: lat,
          lng: lng,
          city: (raw['city'] as String?) ?? '',
          region: (raw['region'] as String?) ?? '',
          country: (raw['country'] as String?) ?? '',
          ip: (raw['ip'] as String?) ?? '',
        );
    }
    return null;
  }

  /// Read-out of the last successful IP-geo check, for the in-app debug panel.
  static GeoSnapshot? lastSnapshot(SharedPreferences prefs) {
    final ts = prefs.getInt(_kCacheTsKey);
    final lastError = prefs.getString(_kCacheErrorKey) ?? '';
    if (ts == null) {
      return lastError.isEmpty
          ? null
          : GeoSnapshot(
              city: '',
              region: '',
              country: '',
              ip: '',
              lat: 0,
              lng: 0,
              distanceKm: 0,
              allowed: true,
              checkedAt: DateTime.fromMillisecondsSinceEpoch(0),
              source: '',
              lastError: lastError,
            );
    }
    return GeoSnapshot(
      city: prefs.getString(_kCacheCityKey) ?? '',
      region: prefs.getString(_kCacheRegionKey) ?? '',
      country: prefs.getString(_kCacheCountryKey) ?? '',
      ip: prefs.getString(_kCacheIpKey) ?? '',
      lat: prefs.getDouble(_kCacheLatKey) ?? 0,
      lng: prefs.getDouble(_kCacheLngKey) ?? 0,
      distanceKm: prefs.getDouble(_kCacheDistKey) ?? 0,
      allowed: prefs.getBool(_kCacheAllowedKey) ?? true,
      checkedAt: DateTime.fromMillisecondsSinceEpoch(ts),
      source: prefs.getString(_kCacheSourceKey) ?? '',
      lastError: lastError,
    );
  }

  /// Great-circle distance in kilometres between two lat/long points.
  static double _haversineKm(
      double lat1, double lng1, double lat2, double lng2) {
    const r = 6371.0;
    final dLat = _deg2rad(lat2 - lat1);
    final dLng = _deg2rad(lng2 - lng1);
    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(_deg2rad(lat1)) *
            math.cos(_deg2rad(lat2)) *
            math.sin(dLng / 2) *
            math.sin(dLng / 2);
    final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
    return r * c;
  }

  static double _deg2rad(double deg) => deg * math.pi / 180.0;
}

class GeoSnapshot {
  final String city;
  final String region;
  final String country;
  final String ip;
  final double lat;
  final double lng;
  final double distanceKm;
  final bool allowed;
  final DateTime checkedAt;
  final String source;
  final String lastError;
  GeoSnapshot({
    required this.city,
    required this.region,
    required this.country,
    required this.ip,
    required this.lat,
    required this.lng,
    required this.distanceKm,
    required this.allowed,
    required this.checkedAt,
    required this.source,
    required this.lastError,
  });
}

class _IpSvc {
  final String name;
  final String url;
  const _IpSvc({required this.name, required this.url});
}

class _LookupResult {
  final double lat;
  final double lng;
  final String city;
  final String region;
  final String country;
  final String ip;
  _LookupResult({
    required this.lat,
    required this.lng,
    required this.city,
    required this.region,
    required this.country,
    required this.ip,
  });
}
