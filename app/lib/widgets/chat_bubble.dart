import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app.dart';
import '../providers/providers.dart';
import '../services/chat_service.dart';
import '../services/notification_service.dart';
import 'keyboard_hide.dart';

/// Floating chat bubble on every screen (owner, 11-Oct-2026): unread badge,
/// and a pop-up card by itself when the shop sends something (bill, reply).
class ChatBubble extends ConsumerStatefulWidget {
  const ChatBubble({super.key});

  @override
  ConsumerState<ChatBubble> createState() => _ChatBubbleState();
}

class _ChatBubbleState extends ConsumerState<ChatBubble> with WidgetsBindingObserver {
  Timer? _t;
  int _unread = 0;
  ChatMsg? _popup;
  int _lastPopupAt = 0;
  String _path = '/';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    appRouter.routerDelegate.addListener(_route);
    _t = Timer.periodic(const Duration(seconds: 30), (_) => _check());
    WidgetsBinding.instance.addPostFrameCallback((_) => _check());
  }

  @override
  void dispose() {
    _t?.cancel();
    appRouter.routerDelegate.removeListener(_route);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.resumed) _check();
  }

  void _route() {
    final p = appRouter.routerDelegate.currentConfiguration.uri.path;
    if (mounted && p != _path) {
      KeyboardHideButton.hide(); // a field on the last screen must not keep the keyboard up
      setState(() => _path = p);
      if (p == '/chat') setState(() { _unread = 0; _popup = null; });
    }
  }

  Future<void> _check() async {
    final prefs = ref.read(sharedPreferencesProvider);
    final mob = ChatService.mobile(prefs);
    if (mob == null || _path == '/chat') return;
    try {
      final msgs = await ChatService.list(ref.read(dioProvider), mob);
      final seen = ChatService.seenAt(prefs);
      final fresh = msgs.where((m) => !m.mine && m.at > seen).toList();
      if (!mounted) return;
      setState(() {
        _unread = fresh.length;
        if (fresh.isNotEmpty && fresh.last.at > _lastPopupAt) {
          _popup = fresh.last; // pop up by itself
          _lastPopupAt = fresh.last.at;
        }
      });
      // …and a phone notification (e.g. the bill: "Sir, please make the payment").
      await ChatService.notifyNew(prefs, ref.read(dioProvider),
          (t, b) => NotificationService.instance.showNow(t, b));
    } catch (_) {}
  }

  void _open() {
    setState(() => _popup = null);
    appRouter.push('/chat');
  }

  @override
  Widget build(BuildContext context) {
    final prefs = ref.read(sharedPreferencesProvider);
    if (ChatService.mobile(prefs) == null || _path == '/chat' || _path.startsWith('/pick')) {
      return const SizedBox.shrink();
    }
    final pad = MediaQuery.of(context).padding.bottom;
    return Stack(children: [
      if (_popup != null)
        Positioned(
          left: 12,
          right: 12,
          bottom: 170 + pad,
          child: Material(
            elevation: 10,
            borderRadius: BorderRadius.circular(14),
            color: const Color(0xFF1B1A18),
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: _open,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
                child: Row(children: [
                  const Icon(Icons.chat_rounded, color: Color(0xFF25D366)),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'AKN ZONE: ${_popup!.text.isNotEmpty ? _popup!.text : (_popup!.file ? '📎 sent you a file' : 'new message')}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
                    ),
                  ),
                  TextButton(onPressed: _open, child: const Text('OPEN')),
                  IconButton(
                    icon: const Icon(Icons.close_rounded, color: Colors.white54, size: 18),
                    onPressed: () => setState(() => _popup = null),
                  ),
                ]),
              ),
            ),
          ),
        ),
      Positioned(
        right: 14,
        bottom: 100 + pad,
        child: Badge(
          isLabelVisible: _unread > 0,
          label: Text('$_unread'),
          child: FloatingActionButton(
            heroTag: 'chat-bubble',
            backgroundColor: const Color(0xFF1B8E3A),
            foregroundColor: Colors.white,
            onPressed: _open,
            child: const Icon(Icons.chat_rounded),
          ),
        ),
      ),
    ]);
  }
}
