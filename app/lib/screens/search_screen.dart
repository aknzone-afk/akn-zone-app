import 'package:catalog_app/widgets/caps_text.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers/providers.dart';
import '../widgets/photo_grid.dart';
import 'share_bar.dart';

class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  late TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: ref.read(filterProvider).query);
  }

  @override
  void dispose() {
    // Clear the persisted query so other screens don't open with a stale
    // search filter applied.
    ref.read(filterProvider.notifier).setQuery('');
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final query = ref.watch(filterProvider).query.trim();
    final results = ref.watch(filteredPhotosProvider);
    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) {
          ref.read(filterProvider.notifier).setQuery('');
        }
      },
      child: Scaffold(
        appBar: AppBar(
          actions: [_SearchSelectAllButton(), _SearchCartButton()],
          title: TextField(
            controller: _ctrl,
            autofocus: true,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              hintText: 'Search by design number…',
              border: InputBorder.none,
              suffixIcon: _ctrl.text.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () {
                        _ctrl.clear();
                        ref.read(filterProvider.notifier).setQuery('');
                        setState(() {});
                      },
                    ),
            ),
            onChanged: (v) {
              ref.read(filterProvider.notifier).setQuery(v);
              setState(() {});
            },
          ),
        ),
        body: query.isEmpty
            ? const _SearchEmptyState()
            : PhotoGrid(photos: results),
        bottomNavigationBar: const SelectionBottomBar(),
      ),
    );
  }
}

/// Small toggle in the search app bar, next to the cart. Tap once to select
/// every result; tap again to clear the selection. Hidden when there are no
/// results to act on.
class _SearchSelectAllButton extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final query = ref.watch(filterProvider).query.trim();
    final results = ref.watch(filteredPhotosProvider);
    final selection = ref.watch(selectionProvider);
    // Only show once the user has typed a design number — with an empty query
    // there are no "results" to select (the grid isn't even shown yet).
    // Owner 12-Oct: SELECT ALL only while photos are being selected (hold).
    if (query.isEmpty || results.isEmpty || selection.isEmpty) return const SizedBox.shrink();
    final ids = results.map((p) => p.id).toList(growable: false);
    final allSelected = ids.every(selection.contains);
    // Labelled (not icon-only) so customers immediately understand what it
    // does without being told.
    return TextButton.icon(
      style: TextButton.styleFrom(
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 8),
      ),
      icon: Icon(
          allSelected ? Icons.remove_done_rounded : Icons.done_all_rounded,
          size: 18),
      label: UText(allSelected ? 'Unselect' : 'Select all',
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
      onPressed: () {
        final notifier = ref.read(selectionProvider.notifier);
        if (allSelected) {
          notifier.clear();
        } else {
          notifier.selectAll(ids);
        }
      },
    );
  }
}

class _SearchCartButton extends ConsumerWidget {
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

class _SearchEmptyState extends StatelessWidget {
  const _SearchEmptyState();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.search_rounded, size: 56, color: scheme.outline),
            const SizedBox(height: 16),
            UText(
              'PLEASE TYPE DESIGN NUMBER TO SEARCH',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.4,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
