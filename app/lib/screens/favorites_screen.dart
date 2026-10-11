import 'package:catalog_app/widgets/caps_text.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../l10n.dart';

import '../models/photo.dart';
import '../providers/providers.dart';
import '../services/order_service.dart';
import '../services/marks_service.dart';
import '../services/picks_service.dart';
import '../services/pieces_service.dart';
import '../services/whatsapp_share.dart';
import '../widgets/min_order_bar.dart';
import '../widgets/photo_grid.dart';
import 'manual_price_screen.dart';

class FavoritesScreen extends ConsumerStatefulWidget {
  const FavoritesScreen({super.key});

  @override
  ConsumerState<FavoritesScreen> createState() => _FavoritesScreenState();
}

class _FavoritesScreenState extends ConsumerState<FavoritesScreen> {
  bool _sending = false;

  /// ORDER NOW: blocked below ₹30,000 (owner: "first make it 30,000").
  void _orderNow(List<Photo> favPhotos) {
    final pc = ref.read(piecesProvider.notifier);
    final marks = ref.read(marksProvider);
    final picks = ref.read(picksProvider);
    final v = OrderService.valueCheck(favPhotos.map((p) {
      final pk = picks[p.id];
      final count = pc.piecesFor(p);
      if (pk != null && !pk.isEmpty) {
        return (price: p.price, qty: pk.minTotal(count), sure: pk.exact(count));
      }
      final n = marks[p.id] ?? count;
      return (price: p.price, qty: n ?? 1, sure: n != null);
    }));
    final parcel = OrderService.activeParcel(ref.read(sharedPreferencesProvider));
    if (!v.below || parcel != null) {
      context.push('/order');
      return;
    }
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.block_rounded, color: Color(0xFFD32F2F), size: 44),
        title: Text(t('Minimum order ${MinOrderBar.minLabel}',
            'कम से कम ${MinOrderBar.minLabel} का ऑर्डर')),
        content: Text(t(
            'Your selection is ${OrderService.formatRupees(v.known)}. First complete ${MinOrderBar.minLabel} — select more designs or more pieces.',
            'आपका सिलेक्शन ${OrderService.formatRupees(v.known)} का है। पहले ${MinOrderBar.minLabel} पूरा करें — और डिज़ाइन या पीस चुनें।')),
        actions: [
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              context.go('/');
            },
            child: Text(t('Select more designs', 'और डिज़ाइन चुनें')),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmClear() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: UText(t('Empty cart?', 'कार्ट खाली करें?')),
        content: UText(
            t('This removes every design from your cart. You cannot undo this.', 'कार्ट के सारे डिज़ाइन हट जाएँगे।')),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: UText(t('Cancel', 'रद्द करें'))),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: UText(t('Clear', 'हटाएँ'))),
        ],
      ),
    );
    if (ok == true) {
      await ref.read(favoritesProvider.notifier).clear();
    }
  }

  Future<void> _sendAll(List<Photo> favPhotos) async {
    if (_sending || favPhotos.isEmpty) return;

    // Step 1 — choose how to price the photos before sharing.
    final mode = await showModalBottomSheet<_PriceMode>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const _PriceModeSheet(),
    );
    if (mode == null || !mounted) return;

    double markupPercent = 0;
    double gstPercent = 0;
    Map<String, int>? manualPrices;

    if (mode == _PriceMode.margin) {
      // Custom margin %, optionally + 5% GST on top.
      final res = await showDialog<({double percent, double gstPercent})>(
        context: context,
        builder: (_) => const _MarkupDialog(),
      );
      if (res == null || !mounted) return;
      markupPercent = res.percent;
      gstPercent = res.gstPercent;
    } else if (mode == _PriceMode.manual) {
      // A screen to type each price by hand.
      final prices = await Navigator.of(context).push<Map<String, int>>(
        MaterialPageRoute(
          builder: (_) => ManualPriceScreen(photos: favPhotos),
        ),
      );
      if (prices == null || !mounted) return;
      manualPrices = prices;
    }
    // mode == order → share at original prices, nothing to change.

    // Step 2 — share as separate pictures or one combined PDF.
    final asPdf = await _chooseShareFormat();
    if (asPdf == null || !mounted) return;

    await _doShare(
      favPhotos,
      markupPercent: markupPercent,
      gstPercent: gstPercent,
      manualPrices: manualPrices,
      asPdf: asPdf,
    );
  }

  /// Final step before WhatsApp: send as separate pictures or one PDF.
  /// Returns true = PDF, false = pictures, null = cancelled.
  Future<bool?> _chooseShareFormat() {
    final scheme = Theme.of(context).colorScheme;
    return showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 16),
            UText('Send as', style: Theme.of(ctx).textTheme.titleMedium),
            const SizedBox(height: 8),
            ListTile(
              leading: Icon(Icons.image_rounded, color: scheme.primary),
              title: const UText('Pictures'),
              subtitle: const UText('Each design as a separate image'),
              onTap: () => Navigator.pop(ctx, false),
            ),
            ListTile(
              leading:
                  Icon(Icons.picture_as_pdf_rounded, color: scheme.primary),
              title: const UText('One PDF'),
              subtitle:
                  const UText('All designs together in a single PDF file'),
              onTap: () => Navigator.pop(ctx, true),
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }

  Future<void> _doShare(
    List<Photo> favPhotos, {
    double markupPercent = 0,
    double gstPercent = 0,
    Map<String, int>? manualPrices,
    bool asPdf = false,
  }) async {
    setState(() => _sending = true);
    try {
      await WhatsAppShare.shareDirectly(
        context: context,
        photos: favPhotos,
        editService: ref.read(editServiceProvider),
        dio: ref.read(dioProvider),
        // No caption — images only, so nothing is forwarded along with them.
        message: null,
        markupPercent: markupPercent,
        gstPercent: gstPercent,
        manualPrices: manualPrices,
        asPdf: asPdf,
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: UText('Share failed: $e')),
      );
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final favs = ref.watch(favoritesProvider);
    final all = ref.watch(photosProvider);
    final favPhotos = all.where((p) => favs.contains(p.id)).toList();
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      // Owner 11-Oct: no "CART · N DESIGN" title — two clear words instead.
      appBar: AppBar(
        titleSpacing: 0,
        title: TextButton.icon(
          onPressed: () => context.push('/orders'),
          icon: const Icon(Icons.receipt_long_outlined, size: 20),
          label: const Text('PAST ORDERS', style: TextStyle(fontWeight: FontWeight.w800)),
        ),
        actions: [
          if (favPhotos.isNotEmpty)
            TextButton(
              onPressed: _confirmClear,
              child: const Text('CLEAR SELECTION',
                  style: TextStyle(fontWeight: FontWeight.w800, color: Color(0xFFD32F2F))),
            ),
          const SizedBox(width: 6),
        ],
      ),
      body: favPhotos.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.shopping_cart_outlined,
                        size: 56, color: scheme.outline),
                    const SizedBox(height: 12),
                    UText(t('Your cart is empty.', 'कार्ट खाली है।'),
                        style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 4),
                    UText(
                      t('Tap the cart icon on any photo to add it here.', 'किसी भी डिज़ाइन पर "सिलेक्ट करें" दबाएँ।'),
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            )
          : PhotoGrid(photos: favPhotos, removeMode: true),
      bottomNavigationBar: favPhotos.isEmpty
          ? null
          : Material(
              elevation: 8,
              color: scheme.surface,
              child: SafeArea(
                top: false,
                minimum: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Consumer(builder: (_, ref, __) {
                      // Pieces per design = sarees in its photo (counted on
                      // the shop PC); the order screen can change them.
                      ref.watch(piecesProvider);
                      final marks = ref.watch(marksProvider);
                      final picks = ref.watch(picksProvider);
                      final edits = ref.watch(editsProvider);
                      WidgetsBinding.instance.addPostFrameCallback((_) => ref
                          .read(marksProvider.notifier)
                          .ensure(favPhotos, edits.keys.toSet()));
                      final pc = ref.read(piecesProvider.notifier);
                      final v = OrderService.valueCheck(favPhotos.map((p) {
                        final pk = picks[p.id];
                        final count = pc.piecesFor(p);
                        // Tap-select wins over everything (sets never dropped).
                        if (pk != null && !pk.isEmpty) {
                          return (
                            price: p.price,
                            qty: pk.minTotal(count),
                            sure: pk.exact(count)
                          );
                        }
                        final n = marks[p.id] ?? count;
                        return (price: p.price, qty: n ?? 1, sure: n != null);
                      }));
                      return Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Builder(builder: (_) {
                          final parcel = OrderService.activeParcel(
                              ref.read(sharedPreferencesProvider));
                          return MinOrderBar(
                              progress: v.progress,
                              below: v.below,
                              amount: v.known,
                              compact: true,
                              addOnTo: parcel == null ? null : 'ORDER NO. ${parcel.serial ?? '-'}',
                              addOnUntil: parcel == null
                                  ? null
                                  : OrderService.untilLabel(parcel.until));
                        }),
                      );
                    }),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: SizedBox(
                            height: 52,
                            child: FilledButton.icon(
                              onPressed: _sending
                                  ? null
                                  : () => _orderNow(favPhotos),
                              icon: const Icon(Icons.shopping_bag_rounded),
                              label: UText(
                                t('Order now  ·  ${favPhotos.length}', 'ऑर्डर करें  ·  ${favPhotos.length}'),
                                style: const TextStyle(
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: 0.6),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        SizedBox(
                          height: 52,
                          child: OutlinedButton.icon(
                            onPressed:
                                _sending ? null : () => _sendAll(favPhotos),
                            icon: _sending
                                ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2))
                                : const Icon(Icons.share_rounded),
                            label: UText(_sending ? '…' : t('Share', 'शेयर'),
                                style: const TextStyle(
                                    fontWeight: FontWeight.w700)),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}

/// What to do with the cart when the user taps Share.
enum _PriceMode { order, margin, manual }

/// Bottom sheet offering the order + pricing paths after the user taps Share.
class _PriceModeSheet extends StatelessWidget {
  const _PriceModeSheet();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 16),
            UText('Send these designs',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            ListTile(
              leading: Icon(Icons.storefront_rounded, color: scheme.primary),
              title: const UText('Send to supplier'),
              subtitle: const UText('AKN ZONE · SURAT — to order'),
              onTap: () => Navigator.pop(context, _PriceMode.order),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 2),
              child: Align(
                alignment: Alignment.centerLeft,
                child: UText(
                  'SEND TO YOUR CUSTOMERS',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.0,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.percent_rounded),
              title: const UText('Add a margin %'),
              subtitle: const UText('Raise every price by the same percentage'),
              onTap: () => Navigator.pop(context, _PriceMode.margin),
            ),
            ListTile(
              leading: const Icon(Icons.edit_rounded),
              title: const UText('Set each price manually'),
              subtitle: const UText('Type a custom price for every design'),
              onTap: () => Navigator.pop(context, _PriceMode.manual),
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }
}

/// Asks the user for a margin percentage to add to every price before sending.
/// Returns:
///   • null  — user cancelled (don't send)
///   • 0     — send with original prices
///   • >0    — add this % to every price and cover the printed price in place
class _MarkupDialog extends StatefulWidget {
  const _MarkupDialog();

  @override
  State<_MarkupDialog> createState() => _MarkupDialogState();
}

class _MarkupDialogState extends State<_MarkupDialog> {
  final _ctrl = TextEditingController();
  double _value = 0;
  bool _gst = false;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: const UText('Add your margin'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          UText(
            'Raise every price by this %. The new price replaces the one '
            'printed on each photo, so the buyer won’t see the original.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _ctrl,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
              labelText: 'Margin %',
              suffixText: '%',
              isDense: true,
              border: OutlineInputBorder(),
            ),
            onChanged: (s) {
              final v = double.tryParse(s.trim());
              setState(() => _value = (v == null || v < 0) ? 0 : v);
            },
          ),
          const SizedBox(height: 4),
          CheckboxListTile(
            value: _gst,
            onChanged: (v) => setState(() => _gst = v ?? false),
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            dense: true,
            title: const UText('Add GST (5%)'),
            subtitle: UText(
              'Adds 5% on top of the marked-up price',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context), // null = cancel
          child: UText(t('Cancel', 'रद्द करें')),
        ),
        FilledButton.icon(
          onPressed: _value > 0
              ? () => Navigator.pop(
                  context, (percent: _value, gstPercent: _gst ? 5.0 : 0.0))
              : null,
          icon: const Icon(Icons.send_rounded, size: 18),
          label: UText(_value > 0
              ? 'Send +${_value % 1 == 0 ? _value.toInt() : _value}%${_gst ? ' +GST' : ''}'
              : 'Send'),
        ),
      ],
    );
  }
}
