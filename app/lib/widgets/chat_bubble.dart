import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app.dart';
import '../providers/providers.dart';
import '../services/chat_service.dart';
import '../services/notification_service.dart';
import 'keyboard_hide.dart';
import 'helpline_icon.dart';
import '../services/app_badge.dart';
import '../services/push_service.dart';

/// Floating chat bubble on every screen (owner, 11-Oct-2026): unread badge,
/// and a pop-up card by itself when the shop sends something (bill, reply).
class ChatBubble extends ConsumerStatefulWidget {
  const ChatBubble({super.key});

  @override
  ConsumerState<ChatBubble> createState() => _ChatBubbleState();
}

class _ChatBubbleState extends ConsumerState<ChatBubble> with WidgetsBindingObserver {
  Timer? _t;
  bool _busy = false; // one poll at a time
  bool _paused = false; // app in background: no polling
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
    PushService.tick.addListener(_check); // a push arrived while the app is open
    WidgetsBinding.instance.addPostFrameCallback((_) => _check());
  }

  @override
  void dispose() {
    _t?.cancel();
    PushService.tick.removeListener(_check);
    appRouter.routerDelegate.removeListener(_route);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    _paused = s != AppLifecycleState.resumed;
    if (!_paused) _check();
  }

  void _route() {
    // The TOP screen (a pushed route like /pick/… is the last match).
    final cfg = appRouter.routerDelegate.currentConfiguration;
    final p = cfg.isEmpty ? cfg.uri.path : cfg.last.matchedLocation;
    if (mounted && p != _path) {
      KeyboardHideButton.hide(); // a field on the last screen must not keep the keyboard up
      // Owner 12-Oct: leaving a folder ends the hold-to-select mode (no
      // "SELECT ALL" / "1 selected" carried into the next folder).
      if (ref.read(selectionProvider).isNotEmpty) ref.read(selectionProvider.notifier).clear();
      setState(() => _path = p);
      if (p == '/chat') {
        AppBadge.set(0);
        setState(() { _unread = 0; _popup = null; });
      }
    }
  }

  Future<void> _check() async {
    final prefs = ref.read(sharedPreferencesProvider);
    if (_busy || _paused || ChatService.mobiles(prefs).isEmpty || _path == '/chat') return;
    _busy = true;
    // ignore: unawaited_futures
    PushService.register(prefs, ref.read(dioProvider)); // phone ↔ its customer numbers
    try {
      // Every number this phone ordered for (owner 11-Oct: a reply in the
      // phone's other number's chat was never shown).
      final msgs = await ChatService.listAll(ref.read(dioProvider), prefs);
      final seen = ChatService.seenAt(prefs);
      final fresh = msgs.where((m) => !m.mine && m.at > seen).toList();
      AppBadge.set(fresh.length); // red count on the app icon
      if (!mounted) return;
      setState(() {
        _unread = fresh.length;
        if (fresh.isNotEmpty && fresh.last.at > _lastPopupAt) {
          _popup = fresh.last; // pop up by itself
          _lastPopupAt = fresh.last.at;
        }
      });
      // The phone already rang by push (or the popup above shows it) — never
      // a second banner for the same message (tester 13-Oct).
      if (fresh.isNotEmpty) await ChatService.markNotified(prefs, fresh.last.at);
    } catch (_) {} finally {
      _busy = false;
    }
  }

  void _open() {
    setState(() => _popup = null);
    openChat();
  }

  @override
  Widget build(BuildContext context) {
    final prefs = ref.read(sharedPreferencesProvider);
    // Owner 12-Oct: the helpline sits on the HOME page only — on other pages
    // just while a new shop message is waiting.
    // Owner 12-Oct (2): the floating helpline shows ONLY while a new shop
    // message is waiting (with its count), on every page. Otherwise the
    // helpline is the HELP button under SEE ORDER in My Orders.
    final waiting = _unread > 0 || _popup != null;
    if (ChatService.mobiles(prefs).isEmpty || _path == '/chat' || _path.startsWith('/pick') || !waiting) {
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
                  const HelplineIcon(size: 30, color: Color(0xFF25D366)),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'B.B SYNTHETICS: ${_popup!.text.isNotEmpty ? _popup!.text : (_popup!.file ? '📎 sent you a file' : 'new message')}',
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
            child: const HelplineIcon(size: 34), // lady with headset = helpline
          ),
        ),
      ),
    ]);
  }
}
