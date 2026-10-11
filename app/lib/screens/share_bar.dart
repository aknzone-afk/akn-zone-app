import 'package:catalog_app/widgets/caps_text.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config.dart';
import '../providers/providers.dart';

/// Bottom action bar shown whenever the user has selected ≥1 photo.
/// Tap the action button to add every selected photo to the cart in one shot.
class SelectionBottomBar extends ConsumerWidget {
  const SelectionBottomBar({super.key});

  Future<void> _addToCart(WidgetRef ref) async {
    final ids = ref.read(selectionProvider).toList();
    if (ids.isEmpty) return;
    final favs = ref.read(favoritesProvider);
    final notifier = ref.read(favoritesProvider.notifier);
    for (final id in ids) {
      if (!favs.contains(id)) await notifier.toggle(id);
    }
    ref.read(selectionProvider.notifier).clear();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selection = ref.watch(selectionProvider);
    if (selection.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final count = selection.length;

    return Material(
      elevation: 8,
      color: scheme.surface,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          child: Row(
            children: [
              IconButton(
                tooltip: 'Clear selection',
                icon: const Icon(Icons.close),
                onPressed: () => ref.read(selectionProvider.notifier).clear(),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: UText('$count selected',
                    style: const TextStyle(fontWeight: FontWeight.w700)),
              ),
              const SizedBox(width: 6),
              FilledButton.icon(
                onPressed: () => _addToCart(ref),
                icon: const Icon(Icons.shopping_cart_rounded),
                label: const UText(
                  'SEND TO CART',
                  style: TextStyle(
                      fontWeight: FontWeight.w700, letterSpacing: 0.5),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
