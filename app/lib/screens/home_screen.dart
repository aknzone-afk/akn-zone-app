import 'package:catalog_app/widgets/caps_text.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config.dart';
import '../models/folder.dart';
import '../providers/providers.dart';
import 'tutorial_screen.dart';
import 'daily_feed_screen.dart';
import '../widgets/bar_button.dart';
import '../widgets/filter_sheet.dart';
import '../widgets/loading_collage.dart';
import '../widgets/photo_stack.dart';
import 'access_control.dart';
import 'share_bar.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Warm every folder's cover in the background (once per launch).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Future<void>.delayed(const Duration(seconds: 3), () => warmAllFolderCovers(ref));
    });
    final catalogAsync = ref.watch(catalogProvider);
    final filter = ref.watch(filterProvider);

    // First-install loading: fullscreen collage with no app bar / nav bar.
    if (catalogAsync.value == null && !catalogAsync.hasError) {
      return const Scaffold(body: LoadingCollage());
    }
    // Owner 14-Oct: up to 5 s more on the collage while the first screen of
    // every folder downloads — no spinning circles inside folders.
    if (catalogAsync.hasValue && ref.watch(firstScreensWarmProvider).isLoading) {
      return const Scaffold(body: LoadingCollage());
    }

    return Scaffold(
      // Owner 12-Oct: only the B.B SYNTHETICS logo (no "Surat saree manufacturer"
      // text) + four boxed buttons with icon AND word.
      appBar: AppBar(
        toolbarHeight: 72,
        leadingWidth: 64,
        // Owner 15-Oct: TUTORIAL sits on the left (where the logo was).
        leading: Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 2, 8),
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () {
              if (Tutorial.videoId(ref.read(sharedPreferencesProvider)) == null) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                    content: Text('How-to-order video coming soon.')));
                return;
              }
              context.push('/tutorial');
            },
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Theme.of(context).colorScheme.outline),
              ),
              child: const Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                Icon(Icons.play_circle_outline_rounded, size: 22),
                Text('HOW TO', style: TextStyle(fontSize: 8.5, fontWeight: FontWeight.w800, letterSpacing: 0.3)),
              ]),
            ),
          ),
        ),
        titleSpacing: 4,
        title: Row(children: [
          Expanded(
            // Owner 15-Oct: DAILY UPDATE (day-wise history, like WhatsApp).
            child: BarButton(
              stacked: true,
              icon: Icons.fiber_new_rounded,
              label: 'DAILY',
              sub: 'UPDATE',
              count: ref.watch(dailyTodayCountProvider),
              onTap: () => context.push('/daily'),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
              child: BarButton(
                  stacked: true,
                  icon: Icons.search_rounded,
                  label: 'SEARCH',
                  onTap: () => context.push('/search'))),
          const SizedBox(width: 6),
          Expanded(
              child: BarButton(
                  stacked: true,
                  icon: Icons.swap_vert_rounded,
                  label: 'SORT',
                  dot: filter.isActive,
                  onTap: () => FilterSheet.show(context))),
          const SizedBox(width: 6),
          Expanded(
              child: BarButton(
                  stacked: true,
                  icon: Icons.shopping_cart_outlined,
                  label: 'MY CART',
                  count: ref.watch(favoritesProvider).length,
                  onTap: () => context.push('/favorites'))),
        ]),
        actions: const [SizedBox(width: 12)],
      ),
      body: RefreshIndicator(
        // Invisible spinner — the refresh happens silently in the background;
        // the user shouldn't see a loading indicator on pull-to-refresh.
        color: Colors.transparent,
        backgroundColor: Colors.transparent,
        elevation: 0,
        strokeWidth: 0,
        onRefresh: () async {
          // Tester 13-Oct: one guarded walk shared with the background
          // re-scan (no second concurrent Drive walk); the version checks
          // start at once and their price reads wait for the walk.
          // 13-Oct crash reports: `ref` dies if the screen rebuilds during
          // the await — the app-wide container does not.
          final c = ProviderScope.containerOf(context, listen: false);
          await c.read(pullToRefreshProvider)();
          await c.read(catalogProvider.future);
        },
        child: _buildBody(ref, catalogAsync),
      ),
      bottomNavigationBar: const SelectionBottomBar(),
    );
  }

  /// Show the big first-time loading screen *only* when there's no prior data
  /// to display. Subsequent refreshes (silent or pull-to-refresh) keep the
  /// previously-cached photos on screen.
  Widget _buildBody(WidgetRef ref, AsyncValue<dynamic> async) {
    final value = async.value;
    if (value == null) {
      if (async.hasError) {
        return _ErrorView(
          message: async.error.toString(),
          onRetry: () => ref.invalidate(catalogProvider),
        );
      }
      // Loading and no prior value: this is the very first run on this device.
      return const LoadingCollage();
    }
    // We have data — show it even if a refresh is in flight.
    final data = value as dynamic;
    if (data.photos.isEmpty) return const _EmptyCatalogView();
    return _FoldersView(updatedAt: data.updatedAt);
  }
}

class _FoldersView extends ConsumerWidget {
  final DateTime updatedAt;
  const _FoldersView({required this.updatedAt});

  String _formatAge(DateTime t) {
    final age = DateTime.now().difference(t);
    if (age.inMinutes < 1) return 'updated just now';
    if (age.inMinutes < 60) return 'updated ${age.inMinutes} min ago';
    if (age.inHours < 24) return 'updated ${age.inHours} h ago';
    return 'updated ${age.inDays} d ago';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final folders = ref.watch(topLevelFoldersProvider);
    final photos = ref.watch(photosProvider);

    return CustomScrollView(
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(3, 0, 3, 96),
          sliver: SliverGrid.builder(
            itemCount: folders.length,
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 220,
              mainAxisSpacing: 3,
              crossAxisSpacing: 3,
              childAspectRatio: 0.82,
            ),
            itemBuilder: (context, i) => _FolderTile(folder: folders[i]),
          ),
        ),
      ],
    );
  }
}

class _FolderTile extends ConsumerWidget {
  final CatalogFolder folder;
  const _FolderTile({required this.folder});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => context.push(
          '/folder/${Uri.encodeComponent(folder.path.isEmpty ? "_root" : folder.path)}'),
      child: Card(
        // Default Card margin (4px all round) doubled the visual gap between
        // tiles — the grid's own spacing is the single source of gap now.
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: folder.coverThumbPath == null
                  ? Container(
                      color: scheme.surfaceContainerLow,
                      child: const Icon(Icons.folder, size: 36))
                  : Padding(
                      // Breathing room so the tilted photos behind the cover
                      // peek out and the tile clearly reads as a folder/stack.
                      padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
                      child: PhotoStack(folder: folder),
                    ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  UText(
                    folder.path.isEmpty ? 'Uncategorized' : folder.displayName,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontFamily: 'Playfair',
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                        height: 1.15,
                        fontFeatures: [FontFeature.liningFigures()]),
                  ),
                  const SizedBox(height: 3),
                  UText(
                    '${folder.photoCount} designs',
                    style: TextStyle(
                      fontSize: 9.5,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 2.0,
                      color: scheme.secondary,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _ErrorView({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const SizedBox(height: 80),
        Icon(Icons.cloud_off_rounded,
            size: 56, color: Theme.of(context).colorScheme.outline),
        const SizedBox(height: 16),
        UText(message,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyLarge),
        const SizedBox(height: 16),
        Center(
          child: FilledButton.tonalIcon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh),
            label: const UText('Retry'),
          ),
        ),
      ],
    );
  }
}

class _HomeCartButton extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = ref.watch(favoritesProvider).length;
    return _cartIconWithBadge(context, count);
  }
}

/// Cart icon with a prominent count badge. Shared across home, folder, and
/// search screens so customers always know how many designs are in their
/// cart and can jump to it from anywhere.
Widget _cartIconWithBadge(BuildContext context, int count) {
  return IconButton(
    tooltip: count == 0
        ? 'Cart (empty)'
        : 'Cart · $count design${count == 1 ? '' : 's'}',
    onPressed: () => context.push('/favorites'),
    icon: Badge(
      isLabelVisible: count > 0,
      backgroundColor: Theme.of(context).colorScheme.primary,
      textColor: Theme.of(context).colorScheme.onPrimary,
      textStyle: const TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w800,
        letterSpacing: 0,
        height: 1.0,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      offset: const Offset(2, -4),
      label: UText('$count'),
      child: const Icon(Icons.shopping_cart_rounded, size: 24),
    ),
  );
}

/// Shop contact + address card surfaced when the customer taps the brand
/// title on the home AppBar. Phone number and map link are tap-through.
void _showShopInfo(BuildContext context) {
  const address =
      '4001-22, 3rd Floor,\nSai Krupa Market,\nRing Road, Surat — 395002';
  const mapsUrl = 'https://maps.app.goo.gl/ZDC7mJpa3jKkJxaU8';
  const phone = '7016638059';

  // Tester 13-Oct: launch directly (like advance_screen) instead of gating on
  // canLaunchUrl, which is false on Android 11+ when the browser/dialer isn't
  // declared in <queries> — the tap silently did nothing.
  Future<void> openUrl(String url) async {
    try {
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (_) {/* no app can open it — nothing to do */}
  }

  showDialog<void>(
    context: context,
    builder: (_) {
      final scheme = Theme.of(context).colorScheme;
      return AlertDialog(
        title: const UText('B.B Synthetics',
            style: TextStyle(fontWeight: FontWeight.w800)),
        contentPadding: const EdgeInsets.fromLTRB(24, 14, 24, 8),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.place_rounded, color: scheme.primary, size: 22),
                const SizedBox(width: 10),
                const Expanded(
                  child: UText(
                    address,
                    style: TextStyle(fontSize: 14, height: 1.4),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            InkWell(
              onTap: () => openUrl(mapsUrl),
              child: Row(
                children: [
                  Icon(Icons.map_rounded, color: scheme.primary, size: 22),
                  const SizedBox(width: 10),
                  UText(
                    'Open in Google Maps',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: scheme.primary,
                      decoration: TextDecoration.underline,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            InkWell(
              onTap: () => openUrl('tel:$phone'),
              child: Row(
                children: [
                  Icon(Icons.call_rounded, color: scheme.primary, size: 22),
                  const SizedBox(width: 10),
                  UText(
                    phone,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: scheme.primary,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          // Account controls only exist once the OTP login gate is active.
          // "Delete Account" is an App Store requirement for apps with login.
          if (kAccessControlEnabled) ...[
            TextButton(
              onPressed: () async {
                Navigator.pop(context);
                await deleteMyAccount(context);
              },
              child: const UText('Delete Account',
                  style: TextStyle(color: Color(0xFFB3261E))),
            ),
          ],
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const UText('Close')),
        ],
      );
    },
  );
}

class _BrandTitle extends ConsumerWidget {
  const _BrandTitle();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        // BB script monogram (transparent PNG). Box constrains so it never
        // gets clipped by the AppBar bounds.
        SizedBox(
          width: 44,
          height: 44,
          child: Padding(
            padding: const EdgeInsets.all(2),
            child: Image.asset(
              'assets/icon/bb_logo.png',
              fit: BoxFit.contain,
              filterQuality: FilterQuality.medium,
            ),
          ),
        ),
        const SizedBox(width: 8),
        GestureDetector(
          onTap: () => _showShopInfo(context),
          behavior: HitTestBehavior.opaque,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: 'B.B SYNTHETICS',
                      style: TextStyle(
                        fontFamily: 'Playfair',
                        fontWeight: FontWeight.w700,
                        fontSize: 18,
                        letterSpacing: 2.0,
                        color: scheme.onSurface,
                        height: 1.0,
                      ),
                    ),
                    WidgetSpan(
                      alignment: PlaceholderAlignment.top,
                      child: Padding(
                        padding: const EdgeInsets.only(left: 2),
                        child: UText(
                          '©',
                          style: TextStyle(
                            fontSize: 9,
                            color: scheme.onSurface.withValues(alpha: 0.65),
                            height: 1.0,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              UText(
                kBrandSubtitle,
                style: TextStyle(
                  fontSize: 8.5,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.8,
                  color: scheme.onSurface.withValues(alpha: 0.50),
                  height: 1.0,
                ),
              ),
              const SizedBox(height: 3),
              Container(
                height: 1.2,
                width: 48,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      scheme.secondary,
                      scheme.secondary.withValues(alpha: 0),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _EmptyCatalogView extends StatelessWidget {
  const _EmptyCatalogView();
  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(32),
      children: [
        const SizedBox(height: 80),
        Icon(Icons.photo_library_outlined,
            size: 56, color: Theme.of(context).colorScheme.outline),
        const SizedBox(height: 16),
        UText('Catalog is empty.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 6),
        UText(
          'No photos found in the shared Drive folder yet.',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }
}
