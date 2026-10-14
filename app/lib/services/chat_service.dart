import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/order.dart';
import 'order_service.dart';
import 'phone_lock.dart';

/// ONE chat per customer (owner, 11-Oct-2026): the party ↔ shop messages for
/// this customer's mobile. The party's messages appear under their latest
/// order in the shop's Party order group; staff answer with a Telegram reply.
class ChatMsg {
  final String id, from, text, by;
  final int at;
  final bool file;
  final String? mime;

  /// The customer mobile this message belongs to (a phone can order for 2).
  String cust = '';
  ChatMsg(this.id, this.from, this.text, this.by, this.at, this.file, this.mime);
  bool get mine => from == 'party';
}

class ChatService {
  static const _cloud = 'https://asia-south1-akn-chat-a7dd8.cloudfunctions.net';
  static const _hdr = {'x-app-key': 'akn-zone-app-v3'};
  static const _kSeen = 'chat_seen_v1';

  static Order? _latest(SharedPreferences p) => OrderService.history(p)
      .where((o) => o.status == OrderStatus.sent)
      .firstOrNull;

  /// Tester 13-Oct: the same customer key as the cloud's custKey — an Indian
  /// number = its last 10 digits (+91 / 0 dropped), a foreign one (7-15
  /// digits) = all its digits. 7-9 digit numbers had no chat before.
  static String? key(String raw) {
    final d = raw.replaceAll(RegExp(r'\D'), '');
    if (d.length > 10 && RegExp(r'^(0|91)+$').hasMatch(d.substring(0, d.length - 10))) {
      return d.substring(d.length - 10);
    }
    return d.length >= 7 && d.length <= 15 ? d : null;
  }

  /// This customer's mobile (its key), from their latest order.
  static String? mobile(SharedPreferences p) {
    final o = _latest(p);
    return o == null ? null : key(o.customer.mobile);
  }

  static String? latestRef(SharedPreferences p) => _latest(p)?.number;

  /// EVERY customer mobile ordered from this phone (newest first, max 3).
  /// Owner 11-Oct: the shop replied in the chat of the phone's other number
  /// and the app never showed it — so all of them are watched.
  static List<String> mobiles(SharedPreferences p) {
    final out = <String>[];
    for (final o in OrderService.history(p).where((o) => o.status == OrderStatus.sent)) {
      final m = key(o.customer.mobile);
      if (m == null) continue;
      if (!out.contains(m)) out.add(m);
      if (out.length == 3) break;
    }
    return out;
  }

  /// Latest order ref for a mobile (a reply goes under that customer's order).
  static String? refFor(SharedPreferences p, String mobile) => OrderService.history(p)
      .where((o) => o.status == OrderStatus.sent && key(o.customer.mobile) == mobile)
      .firstOrNull
      ?.number;

  /// All chats of this phone, merged by time.
  static Future<List<ChatMsg>> listAll(Dio dio, SharedPreferences p) async {
    final all = <ChatMsg>[];
    for (final m in mobiles(p)) {
      for (final x in await list(dio, m)) {
        x.cust = m;
        all.add(x);
      }
    }
    all.sort((a, b) => a.at.compareTo(b.at));
    return all;
  }

  /// Tester 13-Oct: messages already fetched, per mobile — each poll asks the
  /// cloud only for newer ones (the whole chat every 8 s drained the quota).
  static final Map<String, List<ChatMsg>> _cache = {};
  static final Set<String> _relinked = {};

  /// Tester 13-Oct: chats / files are served only to a phone linked to the
  /// number (PhoneLock id). A phone that ordered for it but is not linked
  /// (the lock call failed while ordering, or the shop's /reset) links it
  /// again once — exactly what placing the order does — and retries.
  static Future<Map?> _call(Dio dio, String fn, String mobile, Map<String, dynamic> body, int secs) async {
    for (var i = 0; i < 2; i++) {
      final res = await dio.post<dynamic>('$_cloud/$fn',
          data: {...body, 'mobile': mobile, 'device': await PhoneLock.phoneId()},
          options: Options(headers: _hdr, contentType: Headers.jsonContentType,
              receiveTimeout: Duration(seconds: secs),
              validateStatus: (s) => s != null && s < 500));
      final d = res.data is String ? jsonDecode(res.data as String) : res.data;
      if (d is! Map) return null;
      if (d['error'] == 'not linked' && i == 0 && _relinked.add(mobile)) {
        await PhoneLock.check(dio, mobile);
        continue;
      }
      return d;
    }
    return null;
  }

  static Future<List<ChatMsg>> list(Dio dio, String mobile) async {
    final have = _cache[mobile] ?? <ChatMsg>[];
    // 60-s overlap so a message saved a moment late is never missed (by id).
    final since = have.isEmpty ? 0 : have.last.at - 60000;
    final d = await _call(dio, 'chatList', mobile, {'since': since}, 20);
    if (d == null || d['ok'] != true) return List.of(have);
    final ids = {for (final x in have) x.id};
    final fresh = (d['msgs'] as List)
        .map((m) => ChatMsg('${m['id']}', '${m['from']}', '${m['text'] ?? ''}',
            '${m['by'] ?? ''}', (m['at'] as num).toInt(), m['file'] == true, m['mime'] as String?))
        .where((x) => !ids.contains(x.id));
    final all = [...have, ...fresh]..sort((a, b) => a.at.compareTo(b.at));
    final keep = all.length > 200 ? all.sublist(all.length - 200) : all;
    _cache[mobile] = keep;
    return List.of(keep);
  }

  /// Returns true when the photo was taken as the payment screenshot.
  static Future<bool?> send(Dio dio, String ref, {String text = '', List<int>? image}) async {
    final res = await dio.post<dynamic>('$_cloud/chatSend',
        data: {'ref': ref, 'text': text, if (image != null) 'image': base64Encode(image)},
        options: Options(headers: _hdr, contentType: Headers.jsonContentType,
            sendTimeout: const Duration(seconds: 60), receiveTimeout: const Duration(seconds: 60)));
    final d = res.data is String ? jsonDecode(res.data as String) : res.data;
    if (d is! Map || d['ok'] != true) return null;
    return d['paid'] == true;
  }

  /// Downloaded chat files — newest 60 only (tester 13-Oct: unbounded before).
  static final Map<String, List<int>> _files = {};
  static Future<List<int>?> file(Dio dio, String mobile, String id) async {
    if (_files.containsKey(id)) return _files[id];
    final d = await _call(dio, 'chatFile', mobile, {'id': id}, 40);
    if (d == null || d['ok'] != true) return null;
    if (_files.length >= 60) _files.remove(_files.keys.first);
    return _files[id] = base64Decode(d['data'] as String);
  }

  static const _kNotified = 'chat_notified_v1';

  /// New shop messages since the last notification → one system
  /// notification (used by the background task and on app start).
  static Future<void> notifyNew(SharedPreferences p, Dio dio,
      Future<void> Function(String title, String body) show) async {
    if (mobiles(p).isEmpty) return;
    final msgs = await listAll(dio, p);
    final last = p.getInt(_kNotified) ?? 0;
    final seen = seenAt(p);
    final fresh = msgs.where((m) => !m.mine && m.at > last && m.at > seen).toList();
    if (fresh.isEmpty) return;
    final m = fresh.last;
    await show('B.B SYNTHETICS', m.text.isNotEmpty ? m.text : '📎 You have a new file from B.B SYNTHETICS');
    await p.setInt(_kNotified, m.at);
  }

  /// The app itself showed this message (popup / push) — the background
  /// check must not ring the phone for it again.
  static Future<void> markNotified(SharedPreferences p, int at) async {
    if ((p.getInt(_kNotified) ?? 0) < at) await p.setInt(_kNotified, at);
  }

  static int seenAt(SharedPreferences p) => p.getInt(_kSeen) ?? 0;
  static Future<void> markSeen(SharedPreferences p, int at) => p.setInt(_kSeen, at);
}
