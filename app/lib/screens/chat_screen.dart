import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../providers/providers.dart';
import '../services/chat_service.dart';
import '../services/app_badge.dart';
import '../services/order_service.dart';

/// The customer's single chat with the shop (owner, 11-Oct-2026).
class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key});

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final _ctrl = TextEditingController();
  final _scroll = ScrollController();
  List<ChatMsg> _msgs = [];
  bool _sending = false;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _load();
    // Tester 13-Oct: 20 s (was 8) — each poll now fetches only new messages.
    _poll = Timer.periodic(const Duration(seconds: 20), (_) => _load());
  }

  @override
  void dispose() {
    _poll?.cancel();
    _ctrl.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final prefs = ref.read(sharedPreferencesProvider);
    if (ChatService.mobiles(prefs).isEmpty) return;
    try {
      final m = await ChatService.listAll(ref.read(dioProvider), prefs);
      if (!mounted) return;
      final grew = m.length != _msgs.length;
      setState(() => _msgs = m);
      if (m.isNotEmpty) await ChatService.markSeen(prefs, m.last.at);
      AppBadge.set(0);
      if (grew) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
        });
      }
    } catch (_) {}
  }

  Future<void> _send({List<int>? image}) async {
    final prefs = ref.read(sharedPreferencesProvider);
    // Answer in the chat of the number the shop last wrote to.
    final lastShop = _msgs.where((x) => !x.mine && x.cust.isNotEmpty).lastOrNull;
    final refNo = (lastShop == null ? null : ChatService.refFor(prefs, lastShop.cust)) ??
        ChatService.latestRef(prefs);
    final text = _ctrl.text.trim();
    if (refNo == null || (text.isEmpty && image == null) || _sending) return;
    setState(() => _sending = true);
    final paid = await ChatService.send(ref.read(dioProvider), refNo, text: text, image: image)
        .catchError((_) => null);
    if (!mounted) return;
    setState(() => _sending = false);
    if (paid == null) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Not sent — please check internet and try again.')));
      return;
    }
    _ctrl.clear();
    if (paid) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Payment screenshot received ✓')));
    }
    _load();
  }

  /// Owner 13-Oct: several payment screenshots at once — each one is read
  /// and added to the bill's payments (the cloud keeps the total).
  Future<void> _photo() async {
    final xs = await ImagePicker().pickMultiImage(maxWidth: 1800, imageQuality: 85, limit: 10);
    for (final x in xs) {
      if (!mounted) return;
      await _send(image: await x.readAsBytes());
    }
  }

  @override
  Widget build(BuildContext context) {
    final prefs = ref.read(sharedPreferencesProvider);
    final mob = ChatService.mobile(prefs);
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('CHAT WITH AKN ZONE')),
      body: mob == null
          ? const Center(
              child: Padding(
              padding: EdgeInsets.all(24),
              child: Text('Place your first order to start chatting with us.',
                  textAlign: TextAlign.center),
            ))
          : ListView.builder(
              controller: _scroll,
              padding: const EdgeInsets.all(12),
              itemCount: _msgs.length,
              itemBuilder: (_, i) {
                final m = _msgs[i];
                return Align(
                  alignment: m.mine ? Alignment.centerRight : Alignment.centerLeft,
                  child: Container(
                    margin: const EdgeInsets.symmetric(vertical: 4),
                    padding: const EdgeInsets.all(10),
                    constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.78),
                    decoration: BoxDecoration(
                      color: m.mine ? const Color(0xFFDCF8C6) : scheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (m.file) _ChatImage(mobile: m.cust.isNotEmpty ? m.cust : mob, id: m.id, mime: m.mime),
                        if (m.text.isNotEmpty) Text(m.text, style: const TextStyle(fontSize: 15)),
                        const SizedBox(height: 2),
                        Text(OrderService.formatWhen(DateTime.fromMillisecondsSinceEpoch(m.at)),
                            style: const TextStyle(fontSize: 10, color: Colors.black45)),
                      ],
                    ),
                  ),
                );
              },
            ),
      bottomNavigationBar: mob == null
          ? null
          : SafeArea(
              child: Padding(
                padding: EdgeInsets.fromLTRB(8, 6, 8, 8 + MediaQuery.of(context).viewInsets.bottom),
                child: Row(children: [
                  IconButton(
                    tooltip: 'Send photo / payment screenshot',
                    icon: const Icon(Icons.photo_rounded),
                    onPressed: _sending ? null : _photo,
                  ),
                  Expanded(
                    child: TextField(
                      controller: _ctrl,
                      minLines: 1,
                      maxLines: 4,
                      decoration: const InputDecoration(
                          hintText: 'Type a message…', border: OutlineInputBorder(), isDense: true),
                    ),
                  ),
                  const SizedBox(width: 6),
                  IconButton.filled(
                    onPressed: _sending ? null : () => _send(),
                    icon: _sending
                        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.send_rounded),
                  ),
                ]),
              ),
            ),
    );
  }
}

class _ChatImage extends ConsumerWidget {
  final String mobile, id;
  final String? mime;
  const _ChatImage({required this.mobile, required this.id, this.mime});

  /// Each photo is downloaded once; the 8-s poll rebuilds the list and must
  /// not re-fetch (and blink) every picture. Bounded, oldest dropped.
  static final _bytes = <String, Uint8List>{};
  static final _loading = <String, Future<List<int>?>>{};

  static Future<List<int>?> _fetch(WidgetRef ref, String key, String mobile, String id) {
    final hit = _loading[key];
    if (hit != null) return hit;
    if (_loading.length >= 80) _loading.remove(_loading.keys.first);
    final f = ChatService.file(ref.read(dioProvider), mobile, id).then((b) {
      if (b == null) _loading.remove(key); // failed → tried again next build
      return b;
    });
    _loading[key] = f;
    return f;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Tester 13-Oct: a PDF / Excel / any non-image file from the shop opened
    // as a broken picture (or pointed to VIEW BILL, which shows only the
    // bill) — it is a tap-to-open file tile now (opens / shares the file).
    final mt = mime ?? 'image/jpeg';
    if (!mt.startsWith('image/')) return _FileTile(mobile: mobile, id: id, mime: mt);
    final key = '$mobile/$id';
    final have = _bytes[key];
    if (have != null) return _image(context, have);
    return FutureBuilder<List<int>?>(
      future: _fetch(ref, key, mobile, id),
      builder: (_, s) {
        final b = s.data;
        if (b == null) {
          return const SizedBox(width: 160, height: 120, child: Center(child: CircularProgressIndicator(strokeWidth: 2)));
        }
        final bytes = b is Uint8List ? b : Uint8List.fromList(b); // no second copy
        if (_bytes.length >= 60) _bytes.remove(_bytes.keys.first);
        _bytes[key] = bytes;
        return _image(context, bytes);
      },
    );
  }

  Widget _image(BuildContext context, Uint8List bytes) {
  return GestureDetector(
    onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => Scaffold(
            backgroundColor: Colors.black,
            appBar: AppBar(backgroundColor: Colors.black, foregroundColor: Colors.white),
            body: InteractiveViewer(maxScale: 6, child: Center(child: Image.memory(bytes)))))),
    child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.memory(bytes, width: 220, fit: BoxFit.cover, gaplessPlayback: true,
            errorBuilder: (_, __, ___) => const Text('📎 File (cannot show)'))),
  );
  }
}

class _FileTile extends ConsumerStatefulWidget {
  final String mobile, id, mime;
  const _FileTile({required this.mobile, required this.id, required this.mime});

  @override
  ConsumerState<_FileTile> createState() => _FileTileState();
}

class _FileTileState extends ConsumerState<_FileTile> {
  bool _busy = false;

  static const _ext = {
    'pdf': 'pdf', 'spreadsheetml': 'xlsx', 'ms-excel': 'xls', 'wordprocessingml': 'docx',
    'msword': 'doc', 'zip': 'zip', 'csv': 'csv', 'text/plain': 'txt',
  };

  Future<void> _open() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final b = await ChatService.file(ref.read(dioProvider), widget.mobile, widget.id);
      if (b == null) throw Exception('no file');
      final ext = _ext.entries.where((e) => widget.mime.contains(e.key)).map((e) => e.value).firstOrNull ?? 'bin';
      final dir = await getTemporaryDirectory();
      final f = File('${dir.path}/AKN_ZONE_${widget.id}.$ext');
      await f.writeAsBytes(b, flush: true);
      await Share.shareXFiles([XFile(f.path, mimeType: widget.mime)]);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Could not open the file — please check internet and try again.')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final pdf = widget.mime.contains('pdf');
    return InkWell(
      onTap: _open,
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          _busy
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : Icon(pdf ? Icons.picture_as_pdf_rounded : Icons.attach_file_rounded, size: 20),
          const SizedBox(width: 6),
          Text(pdf ? 'PDF — tap to open' : 'File — tap to open',
              style: const TextStyle(fontWeight: FontWeight.w600)),
        ]),
      ),
    );
  }
}
