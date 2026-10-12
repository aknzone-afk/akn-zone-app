import 'dart:convert';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/order.dart';
import '../providers/providers.dart';
import '../services/order_service.dart';

/// NEW customer: 10% advance before the order goes to the shop (owner,
/// 12-Oct-2026). UPI QR / UPI app / bank transfer to B.B SYNTHETICS, then the
/// payment screenshot is checked by the cloud; only then is the order sent.
class AdvanceScreen extends ConsumerStatefulWidget {
  final String number;
  const AdvanceScreen({super.key, required this.number});

  @override
  ConsumerState<AdvanceScreen> createState() => _AdvanceScreenState();
}

class _AdvanceScreenState extends ConsumerState<AdvanceScreen> {
  static const _upi = 'vyapar.173947529358@hdfcbank';
  static const _qr =
      'https://firebasestorage.googleapis.com/v0/b/akn-chat-a7dd8.firebasestorage.app/o/public%2Fupi-qr.jpg?alt=media&token=b37ef652-5ac6-4242-b241-2f4d90b3b468';
  static const _cloud = 'https://asia-south1-akn-chat-a7dd8.cloudfunctions.net';
  static const _hdr = {'x-app-key': 'akn-zone-app-2026'};

  bool _busy = false;
  String? _error;

  Order? get _order => OrderService.history(ref.read(sharedPreferencesProvider))
      .where((o) => o.number == widget.number)
      .firstOrNull;

  int _due(Order o) {
    final t = o.approxTotal ?? 0;
    if (t <= 0) return 5000;
    return ((t * 0.10) / 10).ceil() * 10; // 10%, rounded up to ₹10
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  Future<void> _start() async {
    final o = _order;
    if (o == null) return;
    try {
      final r = await ref.read(dioProvider).post<dynamic>('$_cloud/advanceStart',
          data: {
            'ref': o.number,
            'due': _due(o),
            'total': o.approxTotal ?? 0,
            'billName': o.customer.billName,
            'mobile': o.customer.mobile,
            'orderAt': o.createdAt.millisecondsSinceEpoch,
          },
          options: Options(headers: _hdr, contentType: Headers.jsonContentType));
      final d = r.data is String ? jsonDecode(r.data as String) : r.data;
      if (d is Map && d['state'] == 'paid') await _paid((d['paid'] as num).toInt(), d['utr'] as String?);
    } catch (_) {}
  }

  Future<void> _payUpi(int due) async {
    final uri = Uri.parse('upi://pay?pa=$_upi&pn=${Uri.encodeComponent('B B SYNTHETICS')}'
        '&am=$due&cu=INR&tn=${Uri.encodeComponent('Advance ${widget.number}')}');
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication).catchError((_) => false);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('No UPI app found — scan the QR code or use bank transfer.')));
    }
  }

  Future<void> _upload() async {
    final x = await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 1800, imageQuality: 85);
    if (x == null || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await ref.read(dioProvider).post<dynamic>('$_cloud/advanceProof',
          data: {'ref': widget.number, 'image': base64Encode(await x.readAsBytes())},
          options: Options(
              headers: _hdr,
              contentType: Headers.jsonContentType,
              sendTimeout: const Duration(seconds: 60),
              receiveTimeout: const Duration(seconds: 120)));
      final d = r.data is String ? jsonDecode(r.data as String) : r.data;
      if (d is Map && d['ok'] == true) {
        await _paid((d['paid'] as num).toInt(), d['utr'] as String?);
        return;
      }
      setState(() => _error = (d is Map ? d['error'] : null)?.toString() ?? 'Could not check — please try again.');
    } catch (_) {
      setState(() => _error = 'No internet — please try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Advance verified → the order now goes to the shop.
  Future<void> _paid(int paid, String? utr) async {
    final prefs = ref.read(sharedPreferencesProvider);
    if (!mounted) return;
    setState(() => _busy = true);
    final o = await OrderService.advancePaid(prefs, ref.read(dioProvider), widget.number, paid, utr);
    if (!mounted) return;
    setState(() => _busy = false);
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.check_circle_rounded, size: 52, color: Color(0xFF2E7D32)),
        title: const Text('Advance received — order placed!'),
        content: Text(
          '${OrderService.formatRupees(paid)} advance verified.\n'
          '${o?.serial != null ? 'ORDER NO. ${o!.serial}\n' : ''}'
          'It will be adjusted in your bill. We will contact you shortly.',
          textAlign: TextAlign.center,
        ),
        actions: [
          FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK')),
        ],
      ),
    );
    if (mounted) context.go('/');
  }

  void _copy(String v, String what) {
    Clipboard.setData(ClipboardData(text: v));
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$what copied')));
  }

  @override
  Widget build(BuildContext context) {
    final o = _order;
    if (o == null) return Scaffold(appBar: AppBar(), body: const Center(child: Text('Order not found.')));
    final due = _due(o);
    const green = Color(0xFF1B8E3A);
    Widget row(String k, String v) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(children: [
            SizedBox(width: 110, child: Text(k, style: const TextStyle(color: Colors.black54))),
            Expanded(child: Text(v, style: const TextStyle(fontWeight: FontWeight.w800))),
            IconButton(
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.copy_rounded, size: 18),
                onPressed: () => _copy(v, k)),
          ]),
        );
    // Phone BACK button: go to the catalogue (not out of the app).
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) context.go('/');
      },
      child: Scaffold(
      appBar: AppBar(
        title: const Text('PAY 10% ADVANCE'),
        // Tester 12-Oct: a way out — the order waits in My Orders.
        leading: IconButton(
          icon: const Icon(Icons.close_rounded),
          onPressed: () {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                content: Text('Your order is saved — pay the advance any time from My Orders.')));
            context.go('/');
          },
        ),
      ),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 32), children: [
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
              color: const Color(0xFFE8F5E9), borderRadius: BorderRadius.circular(12),
              border: Border.all(color: green.withValues(alpha: 0.4))),
          child: Column(children: [
            const Text('To confirm your first order, please pay a 10% advance',
                textAlign: TextAlign.center, style: TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            Text(OrderService.formatRupees(due),
                style: const TextStyle(fontSize: 34, fontWeight: FontWeight.w900, color: green)),
            Text('of approx ${OrderService.formatRupees(o.approxTotal ?? 0)} · adjusted in your bill',
                style: const TextStyle(color: Colors.black54)),
          ]),
        ),
        const SizedBox(height: 14),
        SizedBox(
          height: 52,
          child: FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: green),
            onPressed: () => _payUpi(due),
            icon: const Icon(Icons.account_balance_wallet_rounded),
            label: Text('PAY ${OrderService.formatRupees(due)} WITH UPI APP',
                style: const TextStyle(fontWeight: FontWeight.w900)),
          ),
        ),
        const SizedBox(height: 16),
        const Text('OR SCAN THIS QR', textAlign: TextAlign.center, style: TextStyle(fontWeight: FontWeight.w800)),
        const SizedBox(height: 8),
        Center(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: CachedNetworkImage(imageUrl: _qr, width: 240, fit: BoxFit.contain),
          ),
        ),
        const SizedBox(height: 16),
        const Text('OR BANK TRANSFER (NEFT / RTGS / IMPS)', style: TextStyle(fontWeight: FontWeight.w800)),
        const SizedBox(height: 4),
        row('Account name', 'B.B. SYNTHETICS'),
        row('A/c no.', '270320110001776'),
        row('IFSC', 'BKID0002703'),
        row('Bank', 'BANK OF INDIA'),
        row('UPI ID', _upi),
        const SizedBox(height: 8),
        const Text('⚠️ The name must always be B.B. SYNTHETICS. If any other name shows, it is not our account — do not pay.',
            style: TextStyle(color: Color(0xFFC62828), fontWeight: FontWeight.w700)),
        const SizedBox(height: 18),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Text(_error!, style: const TextStyle(color: Color(0xFFC62828), fontWeight: FontWeight.w800)),
          ),
        SizedBox(
          height: 54,
          child: FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFF1B1A18)),
            onPressed: _busy ? null : _upload,
            icon: _busy
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.upload_rounded),
            label: Text(_busy ? 'CHECKING PAYMENT…' : 'UPLOAD PAYMENT SCREENSHOT',
                style: const TextStyle(fontWeight: FontWeight.w900)),
          ),
        ),
        const SizedBox(height: 8),
        const Text('After the screenshot is verified your order goes to us immediately.',
            textAlign: TextAlign.center, style: TextStyle(color: Colors.black54)),
      ]),
    ),
    );
  }
}
