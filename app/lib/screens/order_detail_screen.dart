import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/order.dart';
import '../models/photo.dart';
import '../providers/providers.dart';
import '../services/order_service.dart';
import '../services/photo_freshness.dart';

/// Tap an order in My Orders → everything in it (owner, 11-Oct-2026): each
/// design's photo exactly as sent (green numbers / SET drawn on it), design
/// no., what was selected, pieces, rate and amount, plus the bill details.
class OrderDetailScreen extends ConsumerStatefulWidget {
  final String number;
  const OrderDetailScreen({super.key, required this.number});

  @override
  ConsumerState<OrderDetailScreen> createState() => _OrderDetailScreenState();
}

class _OrderDetailScreenState extends ConsumerState<OrderDetailScreen> {
  Directory? _dir;

  @override
  void initState() {
    super.initState();
    OrderService.viewDir(widget.number).then((d) {
      if (mounted) setState(() => _dir = d);
    });
  }

  File? _sent(int i) {
    final d = _dir;
    if (d == null) return null;
    final f = File('${d.path}${Platform.pathSeparator}$i.jpg');
    return f.existsSync() ? f : null;
  }

  @override
  Widget build(BuildContext context) {
    final orders = OrderService.history(ref.read(sharedPreferencesProvider));
    final o = orders.where((x) => x.number == widget.number).firstOrNull;
    if (o == null) {
      return Scaffold(appBar: AppBar(), body: const Center(child: Text('Order not found.')));
    }
    final photos = {for (final p in ref.read(photosProvider)) p.id: p};
    final mainSerial = o.addOnTo != null
        ? orders.where((x) => x.number == o.addOnTo).firstOrNull?.serial
        : o.serial;
    final title = o.serial != null
        ? 'ORDER NO. ${o.serial}${o.addOnTo != null ? ' (ADD IN NO. ${mainSerial ?? '-'})' : ''}'
        : (o.addOnTo != null ? 'ADD IN ORDER NO. ${mainSerial ?? '-'}' : (o.awaitingAdvance ? 'WAITING FOR 10% ADVANCE' : 'ORDER (sending…)'));
    final c = o.customer;
    const bold = TextStyle(fontWeight: FontWeight.w800);
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
        children: [
          Card(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(OrderService.formatWhen(o.createdAt), style: const TextStyle(color: Colors.black54)),
                const SizedBox(height: 6),
                Text(c.billName, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
                if (c.address.isNotEmpty) Text(c.address),
                if (c.bookingPlace.isNotEmpty) Text('Booking place: ${c.bookingPlace}'),
                if (c.transport.isNotEmpty) Text('Transport: ${c.transport}'),
                if (c.mobile.isNotEmpty) Text('Mobile: ${c.mobile}'),
                if (o.note.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text('Note: ${o.note}', style: const TextStyle(fontStyle: FontStyle.italic)),
                ],
                const Divider(height: 22),
                Text('${o.items.length} DESIGNS · ${o.totalPcs} PCS'
                    '${o.approxTotal != null ? ' · APPROX ${OrderService.formatRupees(o.approxTotal!)} + 5% GST' : ''}',
                    style: bold),
              ]),
            ),
          ),
          const SizedBox(height: 10),
          for (var i = 0; i < o.items.length; i++)
            _ItemTile(item: o.items[i], file: _sent(i), photo: photos[o.items[i].photoId]),
        ],
      ),
    );
  }
}

class _ItemTile extends StatelessWidget {
  final OrderItem item;
  final File? file;
  final Photo? photo;
  const _ItemTile({required this.item, this.file, this.photo});

  Widget _image({int? w, BoxFit fit = BoxFit.cover}) {
    if (file != null) return Image.file(file!, fit: fit, cacheWidth: w);
    if (photo != null) {
      return CachedNetworkImage(
        imageUrl: photo!.thumbUrl(width: w == null ? 1600 : 400),
        cacheManager: photoCacheManager,
        fit: fit,
        errorWidget: (_, __, ___) => Container(color: const Color(0xFFF1EEE8)),
      );
    }
    return Container(color: const Color(0xFFF1EEE8), child: const Icon(Icons.image_not_supported_outlined));
  }

  void _open(BuildContext context) {
    Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => Scaffold(
              backgroundColor: Colors.black,
              appBar: AppBar(
                  backgroundColor: Colors.black,
                  foregroundColor: Colors.white,
                  title: Text('DESIGN NO. ${item.designNumber ?? '-'}',
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800))),
              body: InteractiveViewer(
                  maxScale: 6, child: SizedBox.expand(child: _image(fit: BoxFit.contain))),
            )));
  }

  @override
  Widget build(BuildContext context) {
    final amount = item.price != null ? item.price! * item.qty : null;
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _open(context),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 120, height: 160, child: _image(w: 360)),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('DESIGN NO. ${item.designNumber ?? '-'}',
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w900)),
                const SizedBox(height: 6),
                if ((item.pick ?? '').isNotEmpty)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                        color: const Color(0xFFE8F5E9), borderRadius: BorderRadius.circular(6)),
                    child: Text(item.pick!.toUpperCase(),
                        style: const TextStyle(fontWeight: FontWeight.w800, color: Color(0xFF1B5E20))),
                  ),
                const SizedBox(height: 6),
                Text('${item.qty} PCS', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                if (item.price != null)
                  Text('${OrderService.formatRupees(item.price!)} × ${item.qty} = ${OrderService.formatRupees(amount!)}'),
                const SizedBox(height: 6),
                const Text('Tap to see big photo', style: TextStyle(fontSize: 11, color: Colors.black45)),
              ]),
            ),
          ),
        ]),
      ),
    );
  }
}
