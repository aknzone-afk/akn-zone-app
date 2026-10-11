import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/order.dart';
import 'order_service.dart';

/// ONE chat per customer (owner, 11-Oct-2026): the party ↔ shop messages for
/// this customer's mobile. The party's messages appear under their latest
/// order in the shop's Party order group; staff answer with a Telegram reply.
class ChatMsg {
  final String id, from, text, by;
  final int at;
  final bool file;
  final String? mime;
  ChatMsg(this.id, this.from, this.text, this.by, this.at, this.file, this.mime);
  bool get mine => from == 'party';
}

class ChatService {
  static const _cloud = 'https://asia-south1-akn-chat-a7dd8.cloudfunctions.net';
  static const _hdr = {'x-app-key': 'akn-zone-app-2026'};
  static const _kSeen = 'chat_seen_v1';

  static Order? _latest(SharedPreferences p) => OrderService.history(p)
      .where((o) => o.status == OrderStatus.sent)
      .firstOrNull;

  /// This customer's mobile (10 digits), from their latest order.
  static String? mobile(SharedPreferences p) {
    final o = _latest(p);
    if (o == null) return null;
    final d = o.customer.mobile.replaceAll(RegExp(r'\D'), '');
    return d.length >= 10 ? d.substring(d.length - 10) : null;
  }

  static String? latestRef(SharedPreferences p) => _latest(p)?.number;

  static Future<List<ChatMsg>> list(Dio dio, String mobile) async {
    final res = await dio.post<dynamic>('$_cloud/chatList',
        data: {'mobile': mobile},
        options: Options(headers: _hdr, contentType: Headers.jsonContentType,
            receiveTimeout: const Duration(seconds: 20)));
    final d = res.data is String ? jsonDecode(res.data as String) : res.data;
    if (d is! Map || d['ok'] != true) return [];
    return (d['msgs'] as List)
        .map((m) => ChatMsg('${m['id']}', '${m['from']}', '${m['text'] ?? ''}',
            '${m['by'] ?? ''}', (m['at'] as num).toInt(), m['file'] == true, m['mime'] as String?))
        .toList();
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

  static final Map<String, List<int>> _files = {};
  static Future<List<int>?> file(Dio dio, String mobile, String id) async {
    if (_files.containsKey(id)) return _files[id];
    final res = await dio.post<dynamic>('$_cloud/chatFile',
        data: {'mobile': mobile, 'id': id},
        options: Options(headers: _hdr, contentType: Headers.jsonContentType,
            receiveTimeout: const Duration(seconds: 40)));
    final d = res.data is String ? jsonDecode(res.data as String) : res.data;
    if (d is! Map || d['ok'] != true) return null;
    return _files[id] = base64Decode(d['data'] as String);
  }

  static const _kNotified = 'chat_notified_v1';

  /// New shop messages since the last notification → one system
  /// notification (used by the background task and on app start).
  static Future<void> notifyNew(SharedPreferences p, Dio dio,
      Future<void> Function(String title, String body) show) async {
    final mob = mobile(p);
    if (mob == null) return;
    final msgs = await list(dio, mob);
    final last = p.getInt(_kNotified) ?? 0;
    final seen = seenAt(p);
    final fresh = msgs.where((m) => !m.mine && m.at > last && m.at > seen).toList();
    if (fresh.isEmpty) return;
    final m = fresh.last;
    await show('AKN ZONE', m.text.isNotEmpty ? m.text : '📎 You have a new file from AKN ZONE');
    await p.setInt(_kNotified, m.at);
  }

  static int seenAt(SharedPreferences p) => p.getInt(_kSeen) ?? 0;
  static Future<void> markSeen(SharedPreferences p, int at) => p.setInt(_kSeen, at);
}
