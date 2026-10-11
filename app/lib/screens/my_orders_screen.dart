import 'package:catalog_app/widgets/caps_text.dart';
import 'package:flutter/material.dart';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
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
  Map<String, ({String? status, String? lr, bool bill})> _st = {};

  @override
  void initState() {
    super.initState();
    _loadStatus();
  }

  Future<void> _loadStatus() async {
    try {
      final sentOrders = OrderService.history(ref.read(sharedPreferencesProvider))
          .where((o) => o.status == OrderStatus.sent)
          .toList();
      final refs = sentOrders.map((o) => o.number).toList();
      final info = {
        for (final o in sentOrders)
          o.number: {
            'mobile': o.customer.mobile,
            'billName': o.customer.billName,
            'serial': o.serial,
            'addOnTo': o.addOnTo,
          }
      };
      final st = await OrderService.fetchStatuses(ref.read(dioProvider), refs, info: info);
      if (mounted) setState(() => _st = st);
    } catch (_) {}
  }

  Future<void> _viewBill(String orderRef) async {
    showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => const Center(child: CircularProgressIndicator()));
    final b = await OrderService.fetchBill(ref.read(dioProvider), orderRef)
        .catchError((_) => null);
    if (!mounted) return;
    Navigator.of(context, rootNavigator: true).pop();
    if (b == null) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Bill not available yet. Please try again.')));
      return;
    }
    if (b.mime.contains('pdf')) {
      final dir = await getTemporaryDirectory();
      final f = File('${dir.path}/BILL${b.billNo != null ? ' ' + b.billNo!.replaceAll('/', '-') : ''}.pdf');
      await f.writeAsBytes(b.bytes, flush: true);
      await Share.shareXFiles([XFile(f.path, mimeType: 'application/pdf')]);
      return;
    }
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
          title: Text(b.billNo != null ? 'BILL ${b.billNo}' : 'BILL'),
          actions: [
            IconButton(
              icon: const Icon(Icons.share_rounded),
              onPressed: () async {
                final dir = await getTemporaryDirectory();
                final f = File('${dir.path}/bill.jpg');
                await f.writeAsBytes(b.bytes, flush: true);
                await Share.shareXFiles([XFile(f.path, mimeType: 'image/jpeg')]);
              },
            ),
          ],
        ),
        body: InteractiveViewer(
            maxScale: 6,
            child: Center(child: Image.memory(Uint8List.fromList(b.bytes)))),
      ),
    ));
  }

  Future<void> _sendPayment(String orderRef) async {
    final x = await ImagePicker().pickImage(
        source: ImageSource.gallery, maxWidth: 1800, imageQuality: 85);
    if (x == null || !mounted) return;
    showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => const Center(child: CircularProgressIndicator()));
    final ok = await OrderService.sendPaymentProof(
            ref.read(dioProvider), orderRef, await x.readAsBytes())
        .catchError((_) => false);
    if (!mounted) return;
    Navigator.of(context, rootNavigator: true).pop();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(ok
            ? 'Payment screenshot sent ✓'
            : 'Could not send. Please try again.')));
    if (ok) _loadStatus();
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
                        if (sent && (_st[o.number]?.bill ?? false))
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Wrap(spacing: 8, runSpacing: 6, children: [
                              FilledButton.icon(
                                style: FilledButton.styleFrom(
                                    visualDensity: VisualDensity.compact),
                                onPressed: () => _viewBill(o.number),
                                icon: const Icon(Icons.receipt_long_rounded, size: 18),
                                label: const Text('VIEW BILL'),
                              ),
                              if (_st[o.number]?.status == 'bill_sent')
                                OutlinedButton.icon(
                                  style: OutlinedButton.styleFrom(
                                      visualDensity: VisualDensity.compact),
                                  onPressed: () => _sendPayment(o.number),
                                  icon: const Icon(Icons.upload_rounded, size: 18),
                                  label: const Text('SEND PAYMENT SCREENSHOT'),
                                ),
                            ]),
                          ),
                        if (sent && (_st[o.number]?.lr ?? '').isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text('📄 ${_st[o.number]!.lr}',
                                style: const TextStyle(fontWeight: FontWeight.w700)),
                          ),
                      ],
                    ),
                    isThreeLine: true,
                    // Owner: tap an order → all its designs, selections, pcs.
                    onTap: () => context.push('/order-detail/${Uri.encodeComponent(o.number)}'),
                    trailing: sent
                        ? TextButton(
                            // Owner: "SEE ORDER" (not Order again) → the full order.
                            onPressed: () => context.push('/order-detail/${Uri.encodeComponent(o.number)}'),
                            child: const Text('SEE ORDER',
                                textAlign: TextAlign.center,
                                style: TextStyle(fontWeight: FontWeight.w900)),
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

  static const _keys = ['received', 'getting_ready', 'bill_sent', 'payment_received', 'dispatched', 'bilty'];
  static const _names = ['Sent to shop', 'Getting order ready', 'Bill sent for payment', 'Payment received', 'Dispatched', 'Bilty'];

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
