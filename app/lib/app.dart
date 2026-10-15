import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'config.dart';
import 'providers/providers.dart';
import 'screens/access_control.dart';
import 'screens/favorites_screen.dart';
import 'screens/folder_screen.dart';
import 'screens/home_screen.dart';
import 'screens/link_screen.dart';
import 'screens/my_orders_screen.dart';
import 'screens/order_screen.dart';
import 'screens/pick_screen.dart';
import 'screens/tutorial_screen.dart';
import 'screens/chat_screen.dart';
import 'screens/order_detail_screen.dart';
import 'screens/advance_screen.dart';
import 'screens/daily_feed_screen.dart';
import 'widgets/chat_bubble.dart';
import 'widgets/keyboard_hide.dart';
import 'screens/whats_new_screen.dart';
import 'services/order_service.dart';
import 'services/pieces_service.dart';
import 'l10n.dart';
import 'screens/markup_screen.dart';
import 'screens/photo_detail_screen.dart';
import 'screens/search_screen.dart';
import 'theme.dart';

/// Photo-id lists arrive as `List<String>` on a normal push, but come back from
/// go_router's restoration codec as `List<dynamic>` after the widget tree is
/// remounted (which the access gate does on every resume). Casting straight to
/// `List<String>` throws there and takes the whole app down to an error screen,
/// so copy element-wise instead.
List<String>? _idList(Object? extra) =>
    extra is List ? extra.map((e) => '$e').toList() : null;

/// Opens the chat once — a push tap / bubble tap while the chat is already
/// open must not stack a second ChatScreen (tester 13-Oct).
void openChat() {
  final cfg = appRouter.routerDelegate.currentConfiguration;
  final top = cfg.isEmpty ? cfg.uri.path : cfg.last.matchedLocation;
  if (top == '/chat') return;
  appRouter.push('/chat');
}

/// Public so the notification service can deep-link (e.g. to the daily-update
/// folder) from outside the widget tree.
final appRouter = GoRouter(
  // An unknown link (old website path, typo) lands on the catalog, never on
  // an error page.
  errorBuilder: (_, __) => const HomeScreen(),
  routes: [
    GoRoute(path: '/', builder: (_, __) => const HomeScreen()),
    GoRoute(path: '/search', builder: (_, __) => const SearchScreen()),
    GoRoute(path: '/favorites', builder: (_, __) => const FavoritesScreen()),
    GoRoute(path: '/order', builder: (_, __) => const OrderScreen()),
    GoRoute(path: '/chat', builder: (_, __) => const ChatScreen()),
    GoRoute(
      path: '/advance/:no',
      builder: (_, s) => AdvanceScreen(number: Uri.decodeComponent(s.pathParameters['no']!)),
    ),
    GoRoute(
      path: '/order-detail/:no',
      builder: (_, s) => OrderDetailScreen(number: Uri.decodeComponent(s.pathParameters['no']!)),
    ),
    GoRoute(
      path: '/tutorial',
      builder: (_, s) =>
          TutorialScreen(mustWatch: s.uri.queryParameters['must'] == '1',
              signup: s.uri.queryParameters['kind'] == 'signup'),
    ),
    GoRoute(
      path: '/pick/:id',
      builder: (_, s) =>
          PickScreen(photoId: Uri.decodeComponent(s.pathParameters['id']!)),
    ),
    GoRoute(path: '/orders', builder: (_, __) => const MyOrdersScreen()),
    // Owner 15-Oct: DAILY UPDATE history (one bubble per day).
    GoRoute(path: '/daily', builder: (_, __) => const DailyFeedScreen()),
    GoRoute(
      path: '/daily/:date',
      builder: (_, s) => DailyDayScreen(date: s.pathParameters['date']!),
    ),
    GoRoute(path: '/whats-new', builder: (_, __) => const WhatsNewScreen()),
    // Links from videos / reels / WhatsApp (https://bbsynthetics.in/... or
    // aknzone://open/...).
    GoRoute(
      path: '/d/:designs',
      builder: (_, s) => DesignLinkScreen(
          designs: Uri.decodeComponent(s.pathParameters['designs']!)),
    ),
    GoRoute(
      path: '/f/:name',
      builder: (_, s) =>
          FolderLinkScreen(name: Uri.decodeComponent(s.pathParameters['name']!)),
    ),
    GoRoute(path: '/app', redirect: (_, __) => '/'),
    GoRoute(path: '/open', redirect: (_, __) => '/'),
    GoRoute(
      path: '/folder/:path',
      builder: (_, state) => FolderScreen(
        folderPath: Uri.decodeComponent(state.pathParameters['path']!),
      ),
    ),
    GoRoute(
      path: '/photo/:id',
      builder: (_, state) {
        final id = Uri.decodeComponent(state.pathParameters['id']!);
        final ids = _idList(state.extra) ?? [id];
        return PhotoDetailScreen(initialPhotoId: id, photoIds: ids);
      },
    ),
    GoRoute(
      path: '/markup',
      builder: (_, state) {
        final ids = _idList(state.extra) ?? const <String>[];
        return MarkupScreen(photoIds: ids);
      },
    ),
  ],
);

class CatalogApp extends ConsumerStatefulWidget {
  const CatalogApp({super.key});

  @override
  ConsumerState<CatalogApp> createState() => _CatalogAppState();
}

class _CatalogAppState extends ConsumerState<CatalogApp>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _sendQueuedOrders();
    _tutorialFirstOpen();
  }

  /// First open: the owner's "how to order" video must be watched once.
  Future<void> _tutorialFirstOpen() async {
    final prefs = ref.read(sharedPreferencesProvider);
    await Tutorial.refresh(prefs, ref.read(dioProvider));
    if (!mounted || !Tutorial.mustWatch(prefs)) return;
    appRouter.push('/tutorial?must=1');
  }

  /// Orders placed while offline go out as soon as the app is opened again.
  void _sendQueuedOrders() {
    final prefs = ref.read(sharedPreferencesProvider);
    if (OrderService.pendingCount(prefs) == 0) return;
    // ignore: discarded_futures
    OrderService.retryPending(prefs, ref.read(dioProvider));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Tester 13-Oct: no new cover seed on resume any more. Covers use the
    // DAILY seed (coverSeedProvider) and are pre-warmed once for that seed;
    // a random seed here picked covers that were never downloaded, so tiles
    // showed blank after switching to WhatsApp and back. Owner rule: covers
    // must never show blank, so the daily seed wins over per-resume change.
    if (state == AppLifecycleState.resumed) {
      // Returning from the background doesn't rebuild the catalog, so run the
      // (throttled) Drive re-scan and replaced-photo check here too.
      ref.read(catalogResumeCheckProvider)();
      _sendQueuedOrders();
      ref.read(piecesProvider.notifier).refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    // Rebuild everything when the language changes.
    return ValueListenableBuilder<bool>(
      valueListenable: hindiNotifier,
      builder: (_, hi, __) => MaterialApp.router(
      key: ValueKey(hi),
      title: kAppTitle,
      theme: buildAppTheme(),
      debugShowCheckedModeBanner: false,
      routerConfig: appRouter,
      // Customer access gate wraps every route: force-update → OTP login →
      // approval check → catalog. A transparent no-op until the access-control
      // backend is configured (kAccessControlEnabled).
      builder: (context, child) => Stack(children: [
            AuthGate(child: child ?? const SizedBox.shrink()),
            const ChatBubble(), // single chat with the shop, pops up by itself
            const KeyboardHideButton(), // owner: a sure way to close the keyboard
          ]),
    ));
  }
}
