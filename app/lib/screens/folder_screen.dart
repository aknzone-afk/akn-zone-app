import 'dart:math';

import 'package:catalog_app/widgets/caps_text.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../config.dart';
import '../models/filter_state.dart' as fs;
import '../models/folder.dart';
import '../models/photo.dart';
import '../providers/providers.dart';
import '../services/drive_urls.dart';
import '../services/photo_freshness.dart';
import '../services/price_check.dart';
import '../services/notification_service.dart' show kDailyUpdateFolder;
import '../widgets/photo_card.dart';
import '../widgets/filter_sheet.dart';
import '../widgets/marquee_text.dart';
import '../widgets/photo_grid.dart';
import '../widgets/photo_stack.dart';
import '../widgets/prefetch_wrap.dart';
import 'share_bar.dart';

String _alnumOnly(String s) =>
    s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

/// Drill-down folder browser. Shows the direct sub-folders + direct files
/// of the current folder — does NOT recurse into sub-folders.
///
/// Special path values:
///   `_all`  — show every photo across the catalog as a flat grid (skips
///             sub-folder tiles)
///   `_root` — show items literally at the root level
///   anything else — that exact folder path
class FolderScreen extends ConsumerStatefulWidget {
  final String folderPath;
  const FolderScreen({super.key, required this.folderPath});

  @override
  ConsumerState<FolderScreen> createState() => _FolderScreenState();
}

class _FolderScreenState extends ConsumerState<FolderScreen> {
  // A fresh random seed per folder-open. The shuffle order stays stable while
  // you browse this folder (no jumping as you scroll/select), and is different
  // the next time you open it.
  final int _shuffleSeed = Random().nextInt(0x7fffffff);

  @override
  Widget build(BuildContext context) {
    final folderPath = widget.folderPath;
    final filter = ref.watch(filterProvider);

    if (folderPath == '_all') {
      // Flat "browse all" view — uses the global filter. PopScope clears the
      // filter when the user backs out so the home screen doesn't open with
      // a stale filter still applied.
      var all = ref.watch(filteredPhotosProvider);
      if (filter.sortBy == fs.SortBy.shuffle) {
        all = [...all]..shuffle(Random(_shuffleSeed));
      }
      return PopScope(
        canPop: true,
        onPopInvokedWithResult: (didPop, _) {
          if (didPop) {
            ref.read(filterProvider.notifier).clear();
          }
        },
        child: _FolderScaffold(
          title: 'All designs',
          crumbs: const ['All'],
          topBar: const SizedBox.shrink(),
          body: PhotoGrid(photos: all),
          selectableIds: all.map((p) => p.id).toList(growable: false),
        ),
      );
    }

    final realPath = folderPath == '_root' ? '' : folderPath;
    // The DAILY UPDATE folder live-refreshes from Drive every time it's opened
    // (from the 9 PM notification OR by browsing in), so it always shows today's
    // newest designs. The provider runs the fast single-folder refresh as a
    // side effect; we ignore its value and keep rendering the fresh contents.
    if (realPath == kDailyUpdateFolder) {
      ref.watch(folderLiveRefreshProvider(realPath));
    }
    final contents = ref.watch(folderContentsProvider(realPath));
    final filteredDirect = _applyFilter(contents.directPhotos, filter,
        favs: ref.watch(favoritesProvider), shuffleSeed: _shuffleSeed);
    final directIds = [for (final p in filteredDirect) p.id];
    WidgetsBinding.instance
        .addPostFrameCallback((_) => prioritizePriceCheck(directIds));
    final crumbs = realPath.isEmpty ? <String>['Catalog'] : realPath.split('/');
    final title = crumbs.last;

    return _FolderScaffold(
      title: title,
      crumbs: crumbs,
      topBar: const SizedBox.shrink(),
      selectableIds: filteredDirect.map((p) => p.id).toList(growable: false),
      body: PrefetchOnChange(
        urls: [
          ...contents.subFolders.where((f) => f.coverThumbPath != null).map(
              (f) => DriveUrls.thumbnail(f.coverThumbPath!,
                  width: kThumbnailWidth)),
          ...filteredDirect.map((p) => p.thumbUrl()),
        ],
        child: CustomScrollView(
          cacheExtent: 2400,
          slivers: [
            if (contents.subFolders.isNotEmpty) ...[
              SliverPadding(
                // Same grid metrics as the home screen so folders look identical
                // at every level.
                padding: const EdgeInsets.fromLTRB(3, 0, 3, 8),
                sliver: SliverGrid.builder(
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 220,
                    mainAxisSpacing: 3,
                    crossAxisSpacing: 3,
                    childAspectRatio: 0.82,
                  ),
                  itemCount: contents.subFolders.length,
                  itemBuilder: (context, i) =>
                      _SubfolderTile(folder: contents.subFolders[i]),
                ),
              ),
            ],
            if (filteredDirect.isNotEmpty) ...[
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 96),
                sliver: SliverGrid.builder(
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 200,
                    mainAxisSpacing: 8,
                    crossAxisSpacing: 8,
                    childAspectRatio: 0.78,
                  ),
                  itemCount: filteredDirect.length,
                  itemBuilder: (context, i) => _GridTile(
                    photo: filteredDirect[i],
                    siblingIds:
                        filteredDirect.map((p) => p.id).toList(growable: false),
                  ),
                ),
              ),
            ],
            if (filteredDirect.isEmpty && contents.subFolders.isEmpty)
              const SliverFillRemaining(
                hasScrollBody: false,
                child: _EmptyFolder(),
              ),
          ],
        ),
      ),
    );
  }

  List<Photo> _applyFilter(
    List<Photo> photos,
    fs.FilterState filter, {
    required Set<String> favs,
    required int shuffleSeed,
  }) {
    final nq = _alnumOnly(filter.query.trim());
    bool matchesText(Photo p) =>
        nq.isEmpty ||
        _alnumOnly(p.fabricName ?? '').contains(nq) ||
        _alnumOnly(p.filename).contains(nq) ||
        _alnumOnly(p.designNumber ?? '').contains(nq);
    bool matchesPrice(Photo p) {
      if (filter.priceRange.min <= 0 && !filter.priceRange.max.isFinite)
        return true;
      final price = p.price;
      if (price == null) return false;
      if (price < filter.priceRange.min) return false;
      if (filter.priceRange.max.isFinite && price > filter.priceRange.max)
        return false;
      return true;
    }

    bool matchesFav(Photo p) => !filter.favoritesOnly || favs.contains(p.id);
    final out = photos
        .where((p) => matchesText(p) && matchesPrice(p) && matchesFav(p))
        .toList();
    // Default order: a fresh random shuffle each time the folder is opened.
    if (filter.sortBy == fs.SortBy.shuffle) {
      return out..shuffle(Random(shuffleSeed));
    }
    Map<String, int>? fabricCounts;
    if (filter.sortBy == fs.SortBy.fabricName) {
      fabricCounts = <String, int>{};
      for (final p in out) {
        final n = p.fabricName;
        if (n != null && n.isNotEmpty) {
          fabricCounts[n] = (fabricCounts[n] ?? 0) + 1;
        }
      }
    }
    int cmp(Photo a, Photo b) {
      switch (filter.sortBy) {
        case fs.SortBy.shuffle:
          return 0; // handled above
        case fs.SortBy.folderThenName:
          final c = a.folder.compareTo(b.folder);
          if (c != 0) return c;
          return a.filename.toLowerCase().compareTo(b.filename.toLowerCase());
        case fs.SortBy.priceAsc:
          return (a.price ?? 1 << 30).compareTo(b.price ?? 1 << 30);
        case fs.SortBy.priceDesc:
          return (b.price ?? -1).compareTo(a.price ?? -1);
        case fs.SortBy.modifiedDesc:
          return Photo.compareNewestFirst(a, b);
        case fs.SortBy.designNumber:
          return (a.designNumber ?? '').compareTo(b.designNumber ?? '');
        case fs.SortBy.fabricName:
          final an = a.fabricName;
          final bn = b.fabricName;
          if (an == null && bn == null) return 0;
          if (an == null) return 1;
          if (bn == null) return -1;
          final ac = fabricCounts![an] ?? 0;
          final bc = fabricCounts![bn] ?? 0;
          if (ac != bc) return bc.compareTo(ac);
          final byName = an.toLowerCase().compareTo(bn.toLowerCase());
          if (byName != 0) return byName;
          return a.filename.toLowerCase().compareTo(b.filename.toLowerCase());
      }
    }

    out.sort(cmp);
    return out;
  }
}

class _FolderScaffold extends ConsumerWidget {
  final String title;
  final List<String> crumbs;
  final Widget topBar;
  final Widget body;

  /// Photos the "Select all" action should drop into the selection set. Empty
  /// = no Select-all button (e.g. a folder that only contains sub-folders).
  final List<String> selectableIds;
  const _FolderScaffold({
    required this.title,
    required this.crumbs,
    required this.topBar,
    required this.body,
    this.selectableIds = const [],
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(
        title: MarqueeText(title,
            style: Theme.of(context).appBarTheme.titleTextStyle ??
                Theme.of(context).textTheme.titleLarge),
        actions: [
          if (selectableIds.isNotEmpty)
            Consumer(
              builder: (context, ref, _) {
                final sel = ref.watch(selectionProvider);
                final allSel = selectableIds.every(sel.contains);
                // Labelled (not icon-only) so customers immediately understand
                // what it does without being told.
                return TextButton.icon(
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                  icon: Icon(
                      allSel
                          ? Icons.remove_done_rounded
                          : Icons.done_all_rounded,
                      size: 18),
                  label: UText(allSel ? 'Unselect' : 'Select all',
                      style: const TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w700)),
                  onPressed: () {
                    final n = ref.read(selectionProvider.notifier);
                    if (allSel) {
                      n.clear();
                    } else {
                      n.selectAll(selectableIds);
                    }
                  },
                );
              },
            ),
          IconButton(
            tooltip: 'Search design number',
            onPressed: () => context.push('/search'),
            icon: const Icon(Icons.search_rounded),
          ),
          IconButton(
            tooltip: 'Filter',
            onPressed: () => FilterSheet.show(context),
            icon: Badge(
              isLabelVisible: ref.watch(filterProvider).isActive,
              child: const Icon(Icons.tune_rounded),
            ),
          ),
          _CartButton(),
        ],
      ),
      body: RefreshIndicator(
        color: Colors.transparent,
        backgroundColor: Colors.transparent,
        elevation: 0,
        strokeWidth: 0,
        onRefresh: () async {
          // Start version checks immediately (light HEAD requests), then walk.
          // ignore: discarded_futures
          ref.read(photoFreshnessProvider)();
          await ref.read(catalogServiceProvider).load(force: true);
          ref.invalidate(catalogProvider);
          await ref.read(catalogProvider.future);
        },
        child: body,
      ),
      bottomNavigationBar: const SelectionBottomBar(),
    );
  }
}

class _CartButton extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = ref.watch(favoritesProvider).length;
    final scheme = Theme.of(context).colorScheme;
    return IconButton(
      tooltip: count == 0
          ? 'Cart (empty)'
          : 'Cart · $count design${count == 1 ? '' : 's'}',
      onPressed: () => context.push('/favorites'),
      icon: Badge(
        isLabelVisible: count > 0,
        backgroundColor: scheme.primary,
        textColor: scheme.onPrimary,
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
}

class _Breadcrumbs extends StatelessWidget {
  final List<String> crumbs;
  const _Breadcrumbs({required this.crumbs});
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
      child: Row(
        children: [
          for (int i = 0; i < crumbs.length; i++) ...[
            UText(
              crumbs[i],
              style: TextStyle(
                fontSize: 12,
                color: i == crumbs.length - 1
                    ? scheme.onSurface
                    : scheme.onSurfaceVariant,
                fontWeight:
                    i == crumbs.length - 1 ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
            if (i < crumbs.length - 1)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child:
                    Icon(Icons.chevron_right, size: 14, color: scheme.outline),
              ),
          ],
        ],
      ),
    );
  }
}

class _CountBar extends ConsumerWidget {
  final int showing;
  final int total;
  const _CountBar({required this.showing, required this.total});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filter = ref.watch(filterProvider);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
      child: Row(
        children: [
          UText(
            total == 0
                ? 'No photos here'
                : '$showing of $total photo${total == 1 ? '' : 's'}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const Spacer(),
          if (filter.isActive)
            TextButton.icon(
              onPressed: () => ref.read(filterProvider.notifier).clear(),
              icon: const Icon(Icons.clear, size: 16),
              label: const UText('Clear filters'),
            ),
        ],
      ),
    );
  }
}

/// Sub-folder tile — identical formatting to the home screen's folder tiles
/// (photo-stack cover + name + design count) so folders look the same at
/// every level of the catalog.
class _SubfolderTile extends StatelessWidget {
  final CatalogFolder folder;
  const _SubfolderTile({required this.folder});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => context.push('/folder/${Uri.encodeComponent(folder.path)}'),
      child: Card(
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
                    folder.displayName,
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

class _GridTile extends ConsumerWidget {
  final Photo photo;
  final List<String> siblingIds;
  const _GridTile({required this.photo, required this.siblingIds});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selection = ref.watch(selectionProvider);
    final selectionMode = selection.isNotEmpty;
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: _PhotoCardProxy(
        photo: photo,
        siblingIds: siblingIds,
        selectionMode: selectionMode,
        selected: selection.contains(photo.id),
      ),
    );
  }
}

/// Tiny proxy so we don't double-import PhotoCard semantics. Uses the real
/// PhotoCard via PhotoGrid's own widget by reusing PhotoGrid wouldn't work
/// inside a sliver, so we drop a direct PhotoCard here.
class _PhotoCardProxy extends ConsumerWidget {
  final Photo photo;
  final List<String> siblingIds;
  final bool selectionMode;
  final bool selected;
  const _PhotoCardProxy({
    required this.photo,
    required this.siblingIds,
    required this.selectionMode,
    required this.selected,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Same tile as everywhere else: one DO SELECTION box, no round icons.
    return PhotoCard(
      photo: photo,
      selectionMode: selectionMode,
      selected: selected,
      onTap: () => context.push(
        '/photo/${Uri.encodeComponent(photo.id)}',
        extra: siblingIds,
      ),
      onLongPress: () => ref.read(selectionProvider.notifier).toggle(photo.id),
      onSelectToggle: () => ref.read(selectionProvider.notifier).toggle(photo.id),
    );
  }
}

class _EmptyFolder extends StatelessWidget {
  const _EmptyFolder();
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.folder_open_outlined,
                size: 48, color: Theme.of(context).colorScheme.outline),
            const SizedBox(height: 12),
            UText(
              'This folder is empty.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }
}
