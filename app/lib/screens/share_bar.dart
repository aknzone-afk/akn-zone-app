import 'package:catalog_app/widgets/caps_text.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config.dart';
import '../providers/providers.dart';
import '../services/picks_service.dart';

/// Bottom action bar shown whenever the user has selected ≥1 photo.
/// Tap the action button to add every selected photo to the cart in one shot.
class SelectionBottomBar extends ConsumerWidget {
  const SelectionBottomBar({super.key});

  /// Tester 13-Oct: true while a SEND TO CART run is in progress — a second
  /// quick tap is ignored instead of racing the first one.
  static bool _adding = false;

  /// Returns false when a previous tap is still adding (nothing done).
  /// 25-Oct: works on the app-wide container, not the bar's `ref` — the bar
  /// can be rebuilt away halfway through ("Cannot use ref after the widget
  /// was disposed", 18 reports) and the rest of the designs never reached
  /// the cart.
  Future<bool> _addToCart(ProviderContainer ref) async {
    if (_adding) return false;
    final ids = ref.read(selectionProvider).toList();
    if (ids.isEmpty) return false;
    _adding = true;
    try {
      final notifier = ref.read(favoritesProvider.notifier);
      // Tester 12-Oct: nothing goes into the cart without a quantity — a bulk
      // "send to cart" adds 1 SET of each design (tap it to change).
      // Tester 13-Oct: picks are read LIVE per design (not a snapshot), the
      // pick is saved BEFORE the design joins the cart (a design with no pick
      // can never be in the cart), and add() never removes.
      for (final id in ids) {
        final pk = ref.read(picksProvider)[id];
        if (pk == null || pk.isEmpty) {
          await ref
              .read(picksProvider.notifier)
              .set(id, const PickState(sets: 1));
        }
        await notifier.add(id);
      }
      ref.read(selectionProvider.notifier).clear();
      return true;
    } finally {
      _adding = false;
    }
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
                onPressed: () async {
                  final n = ref.read(selectionProvider).length;
                  final messenger = ScaffoldMessenger.maybeOf(context);
                  final added = await _addToCart(ProviderScope.containerOf(context, listen: false));
                  if (added && !context.mounted) {
                    messenger?.showSnackBar(SnackBar(
                        content: Text('$n design${n == 1 ? '' : 's'} added as 1 SET each — tap a design to change.')));
                  }
                  if (added && context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                        content: Text('$n design${n == 1 ? '' : 's'} added as 1 SET each — tap a design to change.')));
                  }
                },
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
