import 'package:catalog_app/widgets/caps_text.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../l10n.dart';

import '../models/order.dart';
import '../providers/providers.dart';
import '../services/order_service.dart';

/// Every order placed from this phone, newest first, with its delivery state.
/// Orders that couldn't be sent (no internet) can be re-sent with one tap —
/// they are also retried automatically whenever the app opens.
class MyOrdersScreen extends ConsumerStatefulWidget {
  const MyOrdersScreen({super.key});

  @override
  ConsumerState<MyOrdersScreen> createState() => _MyOrdersScreenState();
}

class _MyOrdersScreenState extends ConsumerState<MyOrdersScreen> {
  String? _busy;
  Map<String, ({String? status, String? lr})> _st = {};

  @override
  void initState() {
    super.initState();
    _loadStatus();
  }

  Future<void> _loadStatus() async {
    try {
      final refs = OrderService.history(ref.read(sharedPreferencesProvider))
          .where((o) => o.status == OrderStatus.sent)
          .map((o) => o.number)
          .toList();
      final st = await OrderService.fetchStatuses(ref.read(dioProvider), refs);
      if (mounted) setState(() => _st = st);
    } catch (_) {}
  }

  Future<void> _retry(String number) async {
    setState(() => _busy = number);
    final o = await OrderService.retryOne(
        ref.read(sharedPreferencesProvider), ref.read(dioProvider), number);
    if (!mounted) return;
    setState(() => _busy = null);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(o?.status == OrderStatus.sent
          ? t('Order $number sent ✓', 'ऑर्डर $number भेज दिया ✓')
          : t('Still no connection — will try again automatically.', 'अभी इंटरनेट नहीं — अपने आप फिर भेजेंगे।')),
    ));
  }

  /// Puts that order's designs back in the cart (those still in the catalog).
  Future<void> _again(Order o) async {
    final all = ref.read(photosProvider).map((p) => p.id).toSet();
    final favs = ref.read(favoritesProvider);
    var added = 0;
    for (final it in o.items) {
      if (all.contains(it.photoId) && !favs.contains(it.photoId)) {
        await ref.read(favoritesProvider.notifier).toggle(it.photoId);
        added++;
      }
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(t('$added designs added to cart — check pieces and order.',
            '$added डिज़ाइन कार्ट में डाले — पीस जाँच कर ऑर्डर करें।'))));
    context.push('/favorites');
  }

  @override
  Widget build(BuildContext context) {
    final orders = OrderService.history(ref.read(sharedPreferencesProvider));
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: UText(t('My orders', 'मेरे ऑर्डर'))),
      body: orders.isEmpty
          ? Center(child: UText(t('No orders yet.', 'अभी कोई ऑर्डर नहीं।')))
          : ListView.separated(
              padding: const EdgeInsets.all(12),
              itemCount: orders.length,
              separatorBuilder: (_, __) => const SizedBox(height: 8),
              itemBuilder: (_, i) {
                final o = orders[i];
                final sent = o.status == OrderStatus.sent;
                return Card(
                  margin: EdgeInsets.zero,
                  child: ListTile(
                    leading: Icon(
                      sent ? Icons.check_circle_rounded : Icons.schedule_rounded,
                      color: sent ? const Color(0xFF2E7D32) : Colors.orange,
                    ),
                    // Owner: show the shop's serial, not the internal AKN id.
                    title: Text(
                        o.addOnTo != null
                            ? 'ADD IN ORDER NO. ${orders.where((x) => x.number == o.addOnTo).firstOrNull?.serial ?? '-'}'
                            : (o.serial != null
                                ? 'ORDER NO. ${o.serial}'
                                : 'ORDER (sending…)'),
                        style: const TextStyle(fontWeight: FontWeight.w700)),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${OrderService.formatWhen(o.createdAt)}\n'
                          '${o.customer.billName} · ${o.items.length} designs · ${o.totalPcs} pcs'
                          '${o.approxTotal != null ? ' · approx ${OrderService.formatRupees(o.approxTotal!)}' : ''}',
                        ),
                        const SizedBox(height: 6),
                        if (sent)
                          _Steps(status: _st[o.number]?.status)
                        else
                          Text(o.lastError ?? t('Waiting to send', 'भेजना बाकी')),
                        if (sent && (_st[o.number]?.lr ?? '').isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text('🚚 ${_st[o.number]!.lr}',
                                style: const TextStyle(fontWeight: FontWeight.w700)),
                          ),
                      ],
                    ),
                    isThreeLine: true,
                    trailing: sent
                        ? TextButton(
                            onPressed: () => _again(o),
                            child: Text(t('Order\nagain', 'फिर से\nऑर्डर'),
                                textAlign: TextAlign.center),
                          )
                        : (_busy == o.number
                            ? const SizedBox(
                                width: 22,
                                height: 22,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2))
                            : IconButton(
                                tooltip: t('Send now', 'अभी भेजें'),
                                icon: Icon(Icons.refresh_rounded,
                                    color: scheme.primary),
                                onPressed: () => _retry(o.number),
                              )),
                  ),
                );
              },
            ),
    );
  }
}


/// Order steps; a big GREEN tick on each one that has happened (owner).
class _Steps extends StatelessWidget {
  final String? status;
  const _Steps({required this.status});

  static const _keys = ['received', 'getting_ready', 'packed', 'dispatched', 'delivered'];
  static const _names = ['Sent to shop', 'Getting order ready', 'Packed', 'Dispatched', 'Delivered'];

  @override
  Widget build(BuildContext context) {
    final done = status == null ? 0 : _keys.indexOf(status!);
    return Wrap(
      spacing: 10,
      runSpacing: 6,
      children: [
        for (var i = 0; i < _keys.length; i++)
          Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(i <= done ? Icons.check_circle_rounded : Icons.radio_button_unchecked,
                size: 22,
                color: i <= done ? const Color(0xFF1B8E3A) : Colors.black26),
            const SizedBox(width: 4),
            Text(_names[i],
                style: TextStyle(
                    fontWeight: i <= done ? FontWeight.w700 : FontWeight.w400,
                    color: i <= done ? const Color(0xFF1B8E3A) : Colors.black45)),
          ]),
      ],
    );
  }
}
