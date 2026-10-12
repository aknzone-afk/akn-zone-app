import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import '../l10n.dart';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config.dart';
import '../models/order.dart';
import '../models/photo.dart';
import 'drive_urls.dart';
import 'edit_service.dart';
import 'picks_service.dart';

/// Result of an India Post pincode lookup.
class PincodeInfo {
  final String district;
  final String state;

  /// Lower-cased place names served by this pincode (post offices, block,
  /// district, division, region) — what a typed Booking Place is checked
  /// against.
  final Set<String> places;
  const PincodeInfo(this.district, this.state, this.places);
  String get label => '$district, $state';
}

/// Places orders: validates the form, renders the photos exactly as the
/// customer selected / marked them, keeps a device-side history + send queue,
/// and posts each order to the shop's Telegram group — all the photos first,
/// then one message with the customer's details, closed by a divider line.
///
/// The bot token + group id are NOT compiled into the app: they are read from
/// [kOrderConfigUrl] on the shop's website, so the bot can be changed or its
/// token replaced at any time without shipping a new app. If that file isn't
/// reachable (or not set up yet) the order is kept on the phone and sent
/// automatically on the next app open — the customer never loses an order.
class OrderService {
  OrderService._();

  static const _kOrdersKey = 'orders_v1';
  static const _kCustomerKey = 'order_customer_v1';
  static const _kConfigCacheKey = 'order_cfg_v1';
  static const _kMaxHistory = 60;

  static const countries = <String>[
    'India',
    'Nepal',
    'Bangladesh',
    'Sri Lanka',
    'Bhutan',
    'United Arab Emirates',
    'Saudi Arabia',
    'Oman',
    'Qatar',
    'Kuwait',
    'Bahrain',
    'United States',
    'United Kingdom',
    'Canada',
    'Australia',
    'New Zealand',
    'Singapore',
    'Malaysia',
    'Mauritius',
    'Fiji',
    'South Africa',
    'Kenya',
    'Other',
  ];

  // ───────────────────────── add-on window ─────────────────────────

  /// Owner, 11-Oct-2026: after an order, the customer may ADD to the same
  /// parcel today and tomorrow with NO ₹30,000 minimum. Returns the main
  /// order's number and when the window closes (midnight after tomorrow), or
  /// null when no window is open.
  /// Owner 12-Oct: the window is 24 HOURS from the main order, and at most
  /// 2 add-ons (no spamming) — after that it is a new order.
  static const kMaxAddOns = 2;
  static ({String number, DateTime until, int? serial, int left})? activeParcel(
      SharedPreferences prefs) {
    final now = DateTime.now();
    final all = history(prefs);
    for (final o in all) {
      if (o.addOnTo != null) continue; // add-ons never extend the window
      final until = o.createdAt.add(const Duration(hours: 24));
      final used = all.where((x) => x.addOnTo == o.number).length;
      if (now.isBefore(until) && used < kMaxAddOns) {
        return (number: o.number, until: until, serial: o.serial, left: kMaxAddOns - used);
      }
      return null; // newest main order is outside its window / used up
    }
    return null;
  }

  static String untilLabel(DateTime until) {
    final h = until.hour % 12 == 0 ? 12 : until.hour % 12;
    final mm = until.minute.toString().padLeft(2, '0');
    final ap = until.hour < 12 ? 'AM' : 'PM';
    final today = DateTime.now();
    final sameDay = until.year == today.year && until.month == today.month && until.day == today.day;
    return '${sameDay ? 'today' : 'tomorrow'} $h:$mm $ap';
  }

  // ───────────────────────── minimum order ─────────────────────────

  /// Judges an order against [kMinOrderValue] the way AKN Chat does:
  /// known value = Σ price × pieces. A design without a price, or whose saree
  /// count isn't known yet (`sure` false), makes the judgement unsure — the
  /// order is then let through and the shop checks it.
  static ({int known, int unpriced, bool below, double progress}) valueCheck(
      Iterable<({int? price, int qty, bool sure})> items) {
    var known = 0, unpriced = 0;
    for (final i in items) {
      if (i.price == null || i.price! <= 0) {
        unpriced++;
      } else {
        known += i.price! * i.qty;
        if (!i.sure) unpriced++;
      }
    }
    // Owner, 11-Oct-2026: STRICT — below ₹30,000 the order is never sent,
    // even if some design's price can't be read (it counts as ₹0).
    final below = known < kMinOrderValue;
    final progress = (known / kMinOrderValue).clamp(0.0, 1.0).toDouble();
    return (known: known, unpriced: unpriced, below: below, progress: progress);
  }

  // ───────────────────────── validation ─────────────────────────

  /// Indian mobile → the bare 10 digits (a +91 / 91 / 0 in front is dropped),
  /// or null if it isn't a valid Indian mobile (10 digits starting 6/7/8/9).
  static String? normalizeIndianMobile(String raw) {
    var d = raw.replaceAll(RegExp(r'\D'), '');
    // "+91 98282 71543", "098282…", "+91 +91 98…" — the last 10 digits count.
    if (d.length > 10 && RegExp(r'^(91|0)+').hasMatch(d)) d = d.substring(d.length - 10);
    if (d.length == 12 && d.startsWith('91')) d = d.substring(2);
    if (d.length == 11 && d.startsWith('0')) d = d.substring(1);
    return RegExp(r'^[6-9]\d{9}$').hasMatch(d) ? d : null;
  }

  /// Foreign number: any starting digit, 7–15 digits (country code included).
  static String? normalizeForeignMobile(String raw) {
    final d = raw.replaceAll(RegExp(r'\D'), '');
    return (d.length >= 7 && d.length <= 15) ? d : null;
  }

  static String? validateMobile(String raw, {required bool india}) {
    if (raw.trim().isEmpty) return t('Enter mobile number', 'मोबाइल नंबर लिखें');
    if (india) {
      return normalizeIndianMobile(raw) == null
          ? t('Enter a valid 10-digit mobile starting with 6, 7, 8 or 9', '6, 7, 8 या 9 से शुरू होने वाला 10 अंक का सही मोबाइल लिखें')
          : null;
    }
    return normalizeForeignMobile(raw) == null
        ? t('Enter the number with country code (7–15 digits)', 'देश कोड के साथ नंबर लिखें (7–15 अंक)')
        : null;
  }

  static String? validatePincode(String raw, {required bool india}) {
    final s = raw.trim();
    if (s.isEmpty) return india ? t('Enter pincode', 'पिनकोड लिखें') : t('Enter postal code', 'पोस्टल कोड लिखें');
    if (india && !RegExp(r'^[1-9]\d{5}$').hasMatch(s)) {
      return t('Pincode must be 6 digits', 'पिनकोड 6 अंक का होना चाहिए');
    }
    return null;
  }

  /// Optional GST / PAN / Aadhaar. Returns the kind it looks like, or an
  /// error string starting with '!' when it's filled but malformed.
  static String? taxIdKind(String raw) {
    final s = raw.toUpperCase().replaceAll(RegExp(r'[\s-]'), '');
    if (s.isEmpty) return null;
    if (RegExp(r'^\d{2}[A-Z]{5}\d{4}[A-Z][1-9A-Z]Z[0-9A-Z]$').hasMatch(s)) {
      return 'GST';
    }
    if (RegExp(r'^[A-Z]{5}\d{4}[A-Z]$').hasMatch(s)) return 'PAN';
    if (RegExp(r'^[2-9]\d{11}$').hasMatch(s)) return 'Aadhaar';
    return '!Not a valid GST (15), PAN (10) or Aadhaar (12) number';
  }

  // ───────────────────────── old customer ─────────────────────────

  static const _cloud = 'https://asia-south1-akn-chat-a7dd8.cloudfunctions.net';

  /// New customer: the same checks the shop's NewPartyBot does before it makes
  /// the Tally ledger (owner 11-Oct-2026). Null = could not check (never blocks).
  static Future<({List<Map> errors, List<Map> soft, String? rename})?> checkNewParty(
      Dio dio, CustomerDetails c) async {
    try {
      final res = await dio.post<dynamic>('$_cloud/checkNewParty',
          data: {'cust': c.toJson()},
          options: Options(
              headers: {'x-app-key': 'akn-zone-app-2026'},
              contentType: Headers.jsonContentType,
              receiveTimeout: const Duration(seconds: 15)));
      final d = res.data is String ? jsonDecode(res.data as String) : res.data;
      if (d is! Map || d['ok'] != true) return null;
      return (
        errors: [for (final e in (d['errors'] as List? ?? const [])) e as Map],
        soft: [for (final e in (d['soft'] as List? ?? const [])) e as Map],
        rename: d['rename'] as String?,
      );
    } catch (_) {
      return null;
    }
  }

  /// Shop status per order (received → getting ready → packed → dispatched)
  /// and the LR / dispatch text the shop replied with.
  static Future<Map<String, ({String? status, String? lr, bool bill})>> fetchStatuses(
      Dio dio, List<String> refs, {Map<String, Map<String, dynamic>> info = const {}}) async {
    if (refs.isEmpty) return {};
    final res = await dio.post<dynamic>(
      '$_cloud/orderStatus',
      data: {'refs': refs, 'info': info},
      options: Options(
          headers: {'x-app-key': 'akn-zone-app-2026'},
          contentType: Headers.jsonContentType,
          receiveTimeout: const Duration(seconds: 20)),
    );
    final d = res.data is String ? jsonDecode(res.data as String) : res.data;
    final out = <String, ({String? status, String? lr, bool bill})>{};
    if (d is Map && d['orders'] is Map) {
      (d['orders'] as Map).forEach((k, v) {
        if (v is Map) {
          out['$k'] = (
            status: v['status'] as String?,
            lr: v['lr'] as String?,
            bill: v['bill'] == true
          );
        }
      });
    }
    return out;
  }

  /// The shop's bill for an order (posted in the Bill group).
  static Future<({List<int> bytes, String mime, String? billNo})?> fetchBill(
      Dio dio, String ref) async {
    final res = await dio.post<dynamic>('$_cloud/billImage',
        data: {'ref': ref},
        options: Options(
            headers: {'x-app-key': 'akn-zone-app-2026'},
            contentType: Headers.jsonContentType,
            receiveTimeout: const Duration(seconds: 40)));
    final d = res.data is String ? jsonDecode(res.data as String) : res.data;
    if (d is! Map || d['ok'] != true) return null;
    return (
      bytes: base64Decode(d['data'] as String),
      mime: '${d['mime'] ?? 'image/jpeg'}',
      billNo: d['billNo'] as String?
    );
  }

  /// Party's payment screenshot → posted under the order in the shop group.
  static Future<bool> sendPaymentProof(Dio dio, String ref, List<int> jpg) async {
    final res = await dio.post<dynamic>('$_cloud/paymentProof',
        data: {'ref': ref, 'image': base64Encode(jpg)},
        options: Options(
            headers: {'x-app-key': 'akn-zone-app-2026'},
            contentType: Headers.jsonContentType,
            sendTimeout: const Duration(seconds: 60),
            receiveTimeout: const Duration(seconds: 60)));
    final d = res.data is String ? jsonDecode(res.data as String) : res.data;
    return d is Map && d['ok'] == true;
  }

  static String statusLabel(String? s) => switch (s) {
        'received' => '✅ Received by shop',
        'getting_ready' => '🧺 Getting your order ready',
        'bill_sent' => '🧾 Bill sent for payment',
        'payment_received' => '💰 Payment received',
        'dispatched' => '🚚 Dispatched',
        'bilty' => '📄 Bilty',
        _ => 'Sent to shop ✓',
      };

  /// Step row for My Orders (owner): every step, ticked once it happened.
  static String stepsLine(String? s) {
    const steps = ['received', 'getting_ready', 'bill_sent', 'payment_received', 'dispatched', 'bilty'];
    const names = ['Sent to shop', 'Getting order ready', 'Bill sent for payment', 'Payment received', 'Dispatched', 'Bilty'];
    final done = s == null ? 0 : steps.indexOf(s);
    return [
      for (var i = 0; i < steps.length; i++)
        i <= done ? '${names[i]} ✓' : names[i],
    ].join('  ›  ');
  }

  static const _lookupUrl =
      'https://asia-south1-akn-chat-a7dd8.cloudfunctions.net/lookupParty';

  /// Parties in Tally that have this mobile (same lookup as the DAILY
  /// CUSTOMER desk). Throws on network trouble.
  /// Parties whose GSTIN / PAN matches (owner 12-Oct).
  static Future<List<Map<String, dynamic>>> lookupPartyByTax(Dio dio, String tax) async {
    final res = await dio.post<dynamic>(
      _lookupUrl,
      data: {'tax': tax},
      options: Options(
        headers: {'x-app-key': 'akn-zone-app-2026'},
        contentType: Headers.jsonContentType,
        receiveTimeout: const Duration(seconds: 20),
      ),
    );
    final d = res.data is String ? jsonDecode(res.data as String) : res.data;
    if (d is! Map || d['ok'] != true) return [];
    return ((d['parties'] ?? const []) as List)
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
  }

  static Future<List<Map<String, dynamic>>> lookupParty(Dio dio, String mobile) async {
    final res = await dio.post<dynamic>(
      _lookupUrl,
      data: {'mobile': mobile},
      options: Options(
        headers: {'x-app-key': 'akn-zone-app-2026'},
        contentType: Headers.jsonContentType,
        receiveTimeout: const Duration(seconds: 20),
      ),
    );
    final d = res.data is String ? jsonDecode(res.data as String) : res.data;
    if (d is! Map || d['ok'] != true) return [];
    return ((d['parties'] ?? const []) as List)
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
  }

  // ───────────────────────── pincode ─────────────────────────

  static final Map<String, PincodeInfo?> _pinCache = {};

  /// India Post lookup. Returns null when the pincode does not exist; throws
  /// on network trouble (callers then simply skip the check).
  static Future<PincodeInfo?> lookupPincode(Dio dio, String pin) async {
    if (_pinCache.containsKey(pin)) return _pinCache[pin];
    final res = await dio.get<dynamic>(
      'https://api.postalpincode.in/pincode/$pin',
      options: Options(
        receiveTimeout: const Duration(seconds: 8),
        responseType: ResponseType.json,
      ),
    );
    var data = res.data;
    if (data is String) data = jsonDecode(data);
    final first = (data is List && data.isNotEmpty) ? data.first : null;
    PincodeInfo? info;
    if (first is Map && first['Status'] == 'Success') {
      final offices = (first['PostOffice'] as List?) ?? const [];
      final places = <String>{};
      String district = '', state = '';
      for (final o in offices) {
        if (o is! Map) continue;
        for (final k in ['Name', 'Block', 'District', 'Division', 'Region']) {
          final v = '${o[k] ?? ''}'.trim().toLowerCase();
          if (v.isNotEmpty && v != 'na') places.add(v);
        }
        district = district.isEmpty ? '${o['District'] ?? ''}' : district;
        state = state.isEmpty ? '${o['State'] ?? ''}' : state;
      }
      if (district.isNotEmpty) info = PincodeInfo(district, state, places);
    }
    _pinCache[pin] = info;
    return info;
  }

  /// True when the typed Booking Place belongs to the pincode's area.
  static bool placeMatches(String typed, PincodeInfo info) {
    String n(String s) => s.toLowerCase().replaceAll(RegExp(r'[^a-z]'), '');
    final t = n(typed);
    if (t.length < 3) return false;
    for (final pl in info.places) {
      final x = n(pl);
      if (x.isEmpty) continue;
      if (x.contains(t) || t.contains(x)) return true;
    }
    return false;
  }

  // ───────────────────────── transports ─────────────────────────

  static List<String>? _transports;
  static Future<List<String>> transports() async {
    if (_transports != null) return _transports!;
    try {
      final raw = await rootBundle.loadString('assets/data/transports.json');
      _transports = (jsonDecode(raw) as List).map((e) => '$e').toList();
    } catch (_) {
      _transports = const [];
    }
    return _transports!;
  }

  // ───────────────────────── saved details + history ─────────────────────────

  static CustomerDetails? savedCustomer(SharedPreferences prefs) {
    final s = prefs.getString(_kCustomerKey);
    if (s == null) return null;
    try {
      return CustomerDetails.fromJson(jsonDecode(s) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  static Future<void> saveCustomer(
      SharedPreferences prefs, CustomerDetails c) async {
    await prefs.setString(_kCustomerKey, jsonEncode(c.toJson()));
  }

  static List<Order> history(SharedPreferences prefs) {
    final s = prefs.getString(_kOrdersKey);
    if (s == null) return [];
    try {
      return (jsonDecode(s) as List)
          .map((e) => Order.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> _saveOrder(SharedPreferences prefs, Order o) async {
    final all = history(prefs);
    final i = all.indexWhere((x) => x.number == o.number);
    if (i >= 0) {
      all[i] = o;
    } else {
      all.insert(0, o);
    }
    while (all.length > _kMaxHistory) {
      all.removeLast();
    }
    await prefs.setString(
        _kOrdersKey, jsonEncode(all.map((e) => e.toJson()).toList()));
  }

  static int pendingCount(SharedPreferences prefs) =>
      history(prefs).where((o) => o.status == OrderStatus.pending).length;

  static String newOrderNumber() {
    final n = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    const abc = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final r = Random.secure();
    final tail = List.generate(3, (_) => abc[r.nextInt(abc.length)]).join();
    return 'AKN-${two(n.day)}${two(n.month)}-${two(n.hour)}${two(n.minute)}-$tail';
  }

  // ───────────────────────── placing an order ─────────────────────────

  /// Folder with the order's photos as sent (small copies kept for the
  /// order-details screen), or null when none were kept.
  static Future<Directory?> viewDir(String number) async {
    final root = await getApplicationSupportDirectory();
    final d = Directory(p.join(root.path, 'orders', number));
    return d.existsSync() ? d : null;
  }

  /// After sending: shrink the photos (~60 KB each) instead of deleting them.
  static Future<void> _keepSmallCopies(Directory dir) async {
    try {
      for (final f in dir.listSync().whereType<File>()) {
        if (!f.path.endsWith('.jpg')) continue;
        final small = await FlutterImageCompress.compressWithList(
          await f.readAsBytes(),
          quality: 70,
          minWidth: 700,
          minHeight: 700,
          format: CompressFormat.jpeg,
        );
        if (small.isNotEmpty) await f.writeAsBytes(small, flush: true);
      }
    } catch (_) {}
  }

  static Future<Directory> _orderDir(String number) async {
    final root = await getApplicationSupportDirectory();
    final d = Directory(p.join(root.path, 'orders', number));
    if (!d.existsSync()) d.createSync(recursive: true);
    return d;
  }

  /// Saves the order + a frozen copy of every photo (as edited / marked by the
  /// customer), then tries to send it. Returns the order; check [Order.status]
  /// to know whether it already reached the shop.
  static Future<Order> place({
    required SharedPreferences prefs,
    required Dio dio,
    required EditService editService,
    required List<Photo> photos,
    required Map<String, int> qty,
    Map<String, PickState> picks = const {},
    Map<String, int> sareeCounts = const {},
    Map<String, String> pickLabels = const {},
    required CustomerDetails customer,
    required String note,
    String? lockNote,
    void Function(String step)? onStep,
  }) async {
    final parcel = activeParcel(prefs);
    final order = Order(
      addOnTo: parcel?.number,
      number: newOrderNumber(),
      createdAt: DateTime.now(),
      items: [
        for (final ph in photos)
          OrderItem(
            photoId: ph.id,
            designNumber: ph.designNumber,
            folder: ph.folder,
            price: ph.price,
            qty: qty[ph.id] ?? 1,
            pick: pickLabels[ph.id],
          ),
      ],
      customer: customer,
      note: note.trim(),
      lockNote: lockNote,
    );

    // Freeze the photos NOW: emptying the cart later wipes the markup, and a
    // queued order must still send exactly what the customer saw.
    onStep?.call('Preparing photos…');
    final dir = await _orderDir(order.number);
    var done = 0;
    final queue = List<int>.generate(photos.length, (i) => i);
    Future<void> worker() async {
      while (queue.isNotEmpty) {
        final i = queue.removeAt(0);
        final ph = photos[i];
        Uint8List? bytes = await editService.read(ph.id);
        if (bytes == null || bytes.isEmpty) {
          try {
            final res = await dio.get<List<int>>(
              DriveUrls.thumbnail(ph.id, width: 1600),
              options: Options(responseType: ResponseType.bytes),
            );
            bytes = Uint8List.fromList(res.data ?? const []);
          } catch (_) {
            bytes = null;
          }
        }
        final pick = picks[ph.id];
        if (bytes != null && bytes.isNotEmpty && pick != null && !pick.isEmpty) {
          bytes = await renderPicks(bytes, pick, sareeCount: sareeCounts[ph.id]);
        }
        if (bytes != null && bytes.isNotEmpty) {
          try {
            final jpg = await FlutterImageCompress.compressWithList(
              bytes,
              quality: 85,
              minWidth: 1600,
              minHeight: 1600,
              format: CompressFormat.jpeg,
            );
            if (jpg.isNotEmpty) bytes = jpg;
          } catch (_) {}
          await File(p.join(dir.path, '$i.jpg'))
              .writeAsBytes(bytes!, flush: true);
        }
        done++;
        onStep?.call('Preparing photos… $done/${photos.length}');
      }
    }

    await Future.wait(List.generate(min(6, max(1, photos.length)), (_) => worker()));
    await _saveOrder(prefs, order);
    await saveCustomer(prefs, customer);

    onStep?.call('Sending order…');
    await _trySend(prefs, dio, order, onStep: onStep);
    return order;
  }

  static bool _retrying = false;

  /// Sends every order still waiting on this phone. Safe to call often.
  static Future<int> retryPending(SharedPreferences prefs, Dio dio) async {
    if (_retrying) return 0;
    _retrying = true;
    var sent = 0;
    try {
      for (final o in history(prefs).reversed) {
        if (o.status != OrderStatus.pending) continue;
        if (await _trySend(prefs, dio, o)) sent++;
      }
    } finally {
      _retrying = false;
    }
    return sent;
  }

  static Future<Order?> retryOne(
      SharedPreferences prefs, Dio dio, String number) async {
    final o = history(prefs).where((x) => x.number == number).firstOrNull;
    if (o == null || o.status == OrderStatus.sent) return o;
    await _trySend(prefs, dio, o);
    return o;
  }

  static Future<({String token, String chatId})?> _config(
      SharedPreferences prefs, Dio dio) async {
    Map<String, dynamic>? cfg;
    try {
      final res = await dio.get<dynamic>(
        '$kOrderConfigUrl?t=${DateTime.now().millisecondsSinceEpoch ~/ 60000}',
        options: Options(
          responseType: ResponseType.plain,
          receiveTimeout: const Duration(seconds: 10),
        ),
      );
      cfg = jsonDecode('${res.data}') as Map<String, dynamic>;
      await prefs.setString(_kConfigCacheKey, jsonEncode(cfg));
    } catch (_) {
      final cached = prefs.getString(_kConfigCacheKey);
      if (cached != null) {
        try {
          cfg = jsonDecode(cached) as Map<String, dynamic>;
        } catch (_) {}
      }
    }
    if (cfg == null || cfg['enabled'] == false) return null;
    final token = '${cfg['bot_token'] ?? ''}'.trim();
    final chat = '${cfg['chat_id'] ?? ''}'.trim();
    if (token.isEmpty || chat.isEmpty) return null;
    return (token: token, chatId: chat);
  }

  static Future<bool> _trySend(SharedPreferences prefs, Dio dio, Order order,
      {void Function(String step)? onStep}) async {
    try {
      final cfg = await _config(prefs, dio);
      if (cfg == null) {
        order.lastError = 'Waiting for connection to the shop';
        await _saveOrder(prefs, order);
        return false;
      }
      final api = 'https://api.telegram.org/bot${cfg.token}';
      final dir = await _orderDir(order.number);

      // 1. Photos, 10 per album (Telegram's limit), each with its caption.
      final items = <(int, OrderItem)>[];
      for (var i = 0; i < order.items.length; i++) {
        if (File(p.join(dir.path, '$i.jpg')).existsSync()) {
          items.add((i, order.items[i]));
        }
      }
      final chunks = <List<(int, OrderItem)>>[];
      for (var i = 0; i < items.length; i += 10) {
        chunks.add(items.sublist(i, min(i + 10, items.length)));
      }
      for (var c = order.photoChunksSent; c < chunks.length; c++) {
        onStep?.call('Sending photos… ${c + 1}/${chunks.length}');
        await _sendAlbum(dio, api, cfg.chatId, dir, chunks[c], order);
        order.photoChunksSent = c + 1;
        await _saveOrder(prefs, order);
      }

      // 2. The customer's details, closed with the divider line.
      // Serial ORDER NO. from the shared cloud counter (same number on retry).
      // Owner 11-Oct: an add-on order gets the NEXT serial too (ORDER NO. 3, 4…).
      if (order.serial == null) {
        final res = await dio.post<dynamic>(
          'https://asia-south1-akn-chat-a7dd8.cloudfunctions.net/nextOrderNo',
          data: {'ref': order.number},
          options: Options(
            headers: {'x-app-key': 'akn-zone-app-2026'},
            contentType: Headers.jsonContentType,
            receiveTimeout: const Duration(seconds: 20),
          ),
        );
        final d = res.data is String ? jsonDecode(res.data as String) : res.data;
        final no = (d is Map && d['ok'] == true) ? (d['no'] as num?)?.toInt() : null;
        if (no == null) throw Exception('order number not available');
        order.serial = no;
        await _saveOrder(prefs, order);
      }
      if (!order.detailsSent) {
        onStep?.call('Sending details…');
        final sent = await _post(dio, '$api/sendMessage', {
          'chat_id': cfg.chatId,
          // One button at a time (owner): the shop's next steps appear as
          // each one is done (cloud tgWebhook / packTimer).
          'reply_markup': jsonEncode({
            'inline_keyboard': [
              [
                {'text': '🧺 Maal nikalna chalu', 'callback_data': 's|g|${order.number}'}
              ],
            ]
          }),
          'text': await detailsText(order,
              mainSerial: order.addOnTo == null
                  ? null
                  : history(prefs)
                      .where((x) => x.number == order.addOnTo)
                      .firstOrNull
                      ?.serial),
          'parse_mode': 'HTML',
          'disable_web_page_preview': 'true',
        });
        order.detailsSent = true;
        await _saveOrder(prefs, order);
        // Link this Telegram message to the order (status + LR replies).
        try {
          final msgId = (sent is Map && sent['result'] is Map)
              ? sent['result']['message_id']
              : null;
          if (msgId != null) {
            await dio.post<dynamic>(
              '$_cloud/registerOrder',
              data: {
                'ref': order.number,
                'chat': cfg.chatId,
                'msg': msgId,
                'text': await detailsText(order,
                    mainSerial: order.addOnTo == null
                        ? null
                        : history(prefs)
                            .where((x) => x.number == order.addOnTo)
                            .firstOrNull
                            ?.serial),
                'mobile': order.customer.mobile,
                'billName': order.customer.billName,
                // New customer: full details → the shop's NewPartyBot makes
                // the Tally ledger (broker YOUTUBE) once the order is taken up.
                if (order.customer.kind != 'old' && order.addOnTo == null)
                  'cust': order.customer.toJson(),
                'serial': order.serial,
                'addOnTo': order.addOnTo,
              },
              options: Options(
                  headers: {'x-app-key': 'akn-zone-app-2026'},
                  contentType: Headers.jsonContentType),
            );
          }
        } catch (_) {}
      }
      // Owner 11-Oct: photos → details → "ORDER NO. N" on its own → two dots.
      if (!order.noSent) {
        await _post(dio, '$api/sendMessage', {
          'chat_id': cfg.chatId,
          'text': '<b>ORDER NO. ${order.serial ?? '-'}</b>',
          'parse_mode': 'HTML',
        });
        order.noSent = true;
        await _saveOrder(prefs, order);
      }
      // Separate message with two dots — closes this order in the group.
      if (!order.dotsSent) {
        await _post(dio, '$api/sendMessage', {
          'chat_id': cfg.chatId,
          'text': '.' + String.fromCharCode(10) + '.',
        });
        order.dotsSent = true;
      }
      order.status = OrderStatus.sent;
      order.lastError = null;
      await _saveOrder(prefs, order);
      await _keepSmallCopies(dir);
      return true;
    } catch (e) {
      order.lastError = e is DioException
          ? 'No internet / server busy — will retry'
          : 'Will retry: $e';
      await _saveOrder(prefs, order);
      return false;
    }
  }

  static String _caption(OrderItem it, int index, int total) {
    final parts = <String>[
      '${index + 1}/$total',
      if (it.designNumber != null && it.designNumber!.isNotEmpty)
        'D.No ${it.designNumber}',
      if (it.price != null) '₹${it.price}',
      it.pick != null ? '${it.pick} (${it.qty} pcs)' : '${it.qty} pcs',
    ];
    final folder = it.folder.split('/').where((s) => s.isNotEmpty).join(' › ');
    return folder.isEmpty ? parts.join(' · ') : '${parts.join(' · ')}\n$folder';
  }

  static Future<void> _sendAlbum(Dio dio, String api, String chatId,
      Directory dir, List<(int, OrderItem)> chunk, Order order) async {
    final total = order.items.length;
    if (chunk.length == 1) {
      final (i, it) = chunk.first;
      await _post(
        dio,
        '$api/sendPhoto',
        FormData.fromMap({
          'chat_id': chatId,
          'photo': await MultipartFile.fromFile(p.join(dir.path, '$i.jpg'),
              filename: '$i.jpg'),
        }),
      );
      return;
    }
    final media = <Map<String, String>>[];
    final form = FormData();
    form.fields.add(MapEntry('chat_id', chatId));
    for (final (i, it) in chunk) {
      media.add({
        'type': 'photo',
        'media': 'attach://p$i',
      });
      form.files.add(MapEntry(
        'p$i',
        await MultipartFile.fromFile(p.join(dir.path, '$i.jpg'),
            filename: '$i.jpg'),
      ));
    }
    form.fields.add(MapEntry('media', jsonEncode(media)));
    await _post(dio, '$api/sendMediaGroup', form, rebuild: () async {
      final f = FormData();
      f.fields.addAll(form.fields);
      for (final (i, _) in chunk) {
        f.files.add(MapEntry(
          'p$i',
          await MultipartFile.fromFile(p.join(dir.path, '$i.jpg'),
              filename: '$i.jpg'),
        ));
      }
      return f;
    });
  }

  /// POST with Telegram's flood-control handling (429 → wait retry_after).
  static Future<dynamic> _post(Dio dio, String url, Object data,
      {Future<Object> Function()? rebuild}) async {
    var body = data;
    for (var attempt = 0; attempt < 4; attempt++) {
      try {
        final res = await dio.post<dynamic>(
          url,
          data: body,
          options: Options(
            sendTimeout: const Duration(seconds: 90),
            receiveTimeout: const Duration(seconds: 60),
            contentType: body is FormData
                ? null
                : Headers.formUrlEncodedContentType,
          ),
        );
        return res.data is String ? jsonDecode(res.data as String) : res.data;
      } on DioException catch (e) {
        final code = e.response?.statusCode;
        if (code == 429 && attempt < 3) {
          var wait = 5;
          final d = e.response?.data;
          try {
            final m = d is String ? jsonDecode(d) : d;
            wait = (m['parameters']?['retry_after'] as int?) ?? 5;
          } catch (_) {}
          await Future<void>.delayed(Duration(seconds: wait + 1));
          // A FormData stream can be read only once — rebuild it to retry.
          if (body is FormData) {
            if (rebuild == null) rethrow;
            body = await rebuild();
          }
          continue;
        }
        rethrow;
      }
    }
  }

  static String _esc(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');

  static String formatWhen(DateTime t) {
    const m = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
    final ap = t.hour < 12 ? 'AM' : 'PM';
    return '${t.day.toString().padLeft(2, '0')}-${m[t.month - 1]}-${t.year} '
        '$h:${t.minute.toString().padLeft(2, '0')} $ap';
  }

  static String formatRupees(int v) {
    final s = v.toString();
    if (s.length <= 3) return '₹$s';
    final last3 = s.substring(s.length - 3);
    var rest = s.substring(0, s.length - 3);
    final parts = <String>[];
    while (rest.length > 2) {
      parts.insert(0, rest.substring(rest.length - 2));
      rest = rest.substring(0, rest.length - 2);
    }
    if (rest.isNotEmpty) parts.insert(0, rest);
    return '₹${parts.join(',')},$last3';
  }

  /// The details message posted under the photos.
  static Future<String> detailsText(Order o, {int? mainSerial}) async {
    final c = o.customer;

    final mobileDigits = c.isIndia
        ? (normalizeIndianMobile(c.mobile) ?? c.mobile)
        : (normalizeForeignMobile(c.mobile) ?? c.mobile);
    final waNumber = c.isIndia ? '91$mobileDigits' : mobileDigits;
    final shownMobile = c.isIndia ? '+91 $mobileDigits' : '+$mobileDigits';
    final kind = taxIdKind(c.taxId);

    final b = StringBuffer();
    if (o.addOnTo != null) {
      b.writeln('➕ <b>ADD IN ORDER NO. ${mainSerial ?? '-'}</b>');
    }
    final total = o.approxTotal;
    b.writeln('📦 ${o.items.length} design${o.items.length == 1 ? '' : 's'} · '
        '${o.totalPcs} pcs${total != null ? ' · approx ${formatRupees(total)}' : ''}');
    final unpriced = o.items.where((i) => i.price == null || i.price! <= 0).length;
    if (unpriced > 0) {
      b.writeln('⚠️ <b>$unpriced design${unpriced == 1 ? '' : 's'} without price</b>');
    }
    if ((o.lockNote ?? '').isNotEmpty) b.writeln(_esc(o.lockNote!));
    if (c.kind == 'old') {
      // Owner: for an old customer only these — the rest is in Tally (and no
      // "OLD CUSTOMER" line; only a NEW customer is marked).
      b.writeln();
      b.writeln('👤 <b>Bill Name:</b> ${_esc(c.billName)}');
      b.writeln('📍 <b>Booking Place:</b> ${_esc(c.bookingPlace)}');
    } else {
      if (!c.isIndia) b.writeln('🌍 <b>Country: ${_esc(c.country.toUpperCase())}</b>');
      b.writeln('🆕 <b>NEW CUSTOMER</b>');
      b.writeln();
      b.writeln('👤 <b>Bill Name:</b> ${_esc(c.billName)}');
      b.writeln('🏠 <b>Address:</b> ${_esc(c.address)}');
      b.writeln('📍 <b>Booking Place:</b> ${_esc(c.bookingPlace)}');
      b.writeln('📮 <b>${c.isIndia ? 'Pincode' : 'Postal Code'}:</b> ${_esc(c.pincode)}');
      b.writeln('📱 <b>Mobile:</b> ${_esc(shownMobile)} · '
          '<a href="https://wa.me/$waNumber">WhatsApp</a>');
      b.writeln('🚚 <b>Transport:</b> ${_esc(c.transport.isEmpty ? '-' : c.transport)}');
      if (c.taxId.trim().isNotEmpty) {
        final label = (kind != null && !kind.startsWith('!')) ? kind : 'GST/PAN/Aadhaar';
        b.writeln('🧾 <b>$label:</b> ${_esc(c.taxId.trim().toUpperCase())}');
      }
    }
    if (o.note.isNotEmpty) b.writeln('📝 <b>Note:</b> ${_esc(o.note)}');
    // Owner: no date / phone / app version. "ORDER NO. N" and the two dots
    // go as their own messages right after (see _trySend).
    return b.toString().trimRight();
  }
}
