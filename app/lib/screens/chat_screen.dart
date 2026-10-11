import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../providers/providers.dart';
import '../services/chat_service.dart';
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
    _poll = Timer.periodic(const Duration(seconds: 8), (_) => _load());
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
    final mob = ChatService.mobile(prefs);
    if (mob == null) return;
    try {
      final m = await ChatService.list(ref.read(dioProvider), mob);
      if (!mounted) return;
      final grew = m.length != _msgs.length;
      setState(() => _msgs = m);
      if (m.isNotEmpty) await ChatService.markSeen(prefs, m.last.at);
      if (grew) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
        });
      }
    } catch (_) {}
  }

  Future<void> _send({List<int>? image}) async {
    final prefs = ref.read(sharedPreferencesProvider);
    final refNo = ChatService.latestRef(prefs);
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

  Future<void> _photo() async {
    final x = await ImagePicker().pickImage(
        source: ImageSource.gallery, maxWidth: 1800, imageQuality: 85);
    if (x == null) return;
    await _send(image: await x.readAsBytes());
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
                        if (!m.mine)
                          Text(m.by.isNotEmpty ? 'AKN ZONE · ${m.by}' : 'AKN ZONE',
                              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800)),
                        if (m.file) _ChatImage(mobile: mob, id: m.id, mime: m.mime),
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

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if ((mime ?? '').contains('pdf')) {
      return const Padding(padding: EdgeInsets.all(4), child: Text('📄 PDF bill (see My Orders → VIEW BILL)'));
    }
    return FutureBuilder<List<int>?>(
      future: ChatService.file(ref.read(dioProvider), mobile, id),
      builder: (_, s) {
        final b = s.data;
        if (b == null) {
          return const SizedBox(width: 160, height: 120, child: Center(child: CircularProgressIndicator(strokeWidth: 2)));
        }
        final bytes = Uint8List.fromList(b);
        return GestureDetector(
          onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
              builder: (_) => Scaffold(
                  backgroundColor: Colors.black,
                  appBar: AppBar(backgroundColor: Colors.black, foregroundColor: Colors.white),
                  body: InteractiveViewer(maxScale: 6, child: Center(child: Image.memory(bytes)))))),
          child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.memory(bytes, width: 220, fit: BoxFit.cover)),
        );
      },
    );
  }
}
