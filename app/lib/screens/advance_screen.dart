import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

import '../models/order.dart';
import '../providers/providers.dart';
import '../services/order_service.dart';
import '../services/upi_qr.dart';

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
  static const _cloud = 'https://asia-south1-akn-chat-a7dd8.cloudfunctions.net';
  static const _hdr = {'x-app-key': 'akn-zone-app-v3'};

  bool _busy = false;
  String? _error;

  Order? get _order => OrderService.history(ref.read(sharedPreferencesProvider))
      .where((o) => o.number == widget.number)
      .firstOrNull;

  int _due(Order o) {
    if (OrderService.isTrial(o.number)) return 5; // owner's ₹5 trial
    if (OrderService.liveTest(ref.read(sharedPreferencesProvider), o.customer.billName)) return 5; // LIVE TEST
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
    setState(() => _busy = true); // tester 13-Oct: no upload until we know
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
    } catch (_) {} finally {
      if (mounted) setState(() => _busy = false);
    }
  }


  /// The QR as a picture: Save it (or share it to the UPI app), then in the
  /// UPI app "Scan QR" → gallery. Works even when a link is refused.

  /// Owner 13-Oct: one or SEVERAL screenshots (₹2,000 + ₹1,000 + …) — each
  /// is read by the cloud, which adds them up; done when the total covers it.
  Future<void> _upload() async {
    final xs = await ImagePicker().pickMultiImage(maxWidth: 1800, imageQuality: 85, limit: 10);
    if (xs.isEmpty || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    String? last;
    try {
      for (var i = 0; i < xs.length; i++) {
        // Read on the phone first (free, 1-2 s) — the cloud only falls back to
        // its AI when this text is unclear (owner 13-Oct: checking was slow).
        var ocr = '';
        try {
          final rec = TextRecognizer(script: TextRecognitionScript.latin);
          ocr = (await rec.processImage(InputImage.fromFilePath(xs[i].path))).text;
          await rec.close();
        } catch (_) {}
        final r = await ref.read(dioProvider).post<dynamic>('$_cloud/advanceProof',
            data: {'ref': widget.number, 'image': base64Encode(await xs[i].readAsBytes()), 'ocr': ocr},
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
        final msg = (d is Map ? d['error'] : null)?.toString() ?? 'Could not check — please try again.';
        last = xs.length > 1 ? 'Screenshot ${i + 1} of ${xs.length}: $msg' : msg;
      }
      setState(() => _error = last);
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
        title: Text(OrderService.isTrial(widget.number)
            ? 'TRIAL PASSED — ₹5 screenshot verified!'
            : 'Token received — order placed!'),
        content: Text(
          '${OrderService.formatRupees(paid)} token verified.\n'
          '${o?.serial != null ? 'ORDER NO. ${o!.serial}\n' : ''}'
          'It will be deducted from your final bill.\n'
          'Now we will process the order and send you the final bill within 2 to 3 working days.',
          textAlign: TextAlign.center,
        ),
        actions: [
          FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK')),
        ],
      ),
    );
    if (mounted) context.go('/');
  }

  @override
  Widget build(BuildContext context) {
    final o = _order;
    if (o == null) return Scaffold(appBar: AppBar(), body: const Center(child: Text('Order not found.')));
    final due = _due(o);
    const green = Color(0xFF1B8E3A);
    // Phone BACK button: go to the catalogue (not out of the app).
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) context.go('/');
      },
      child: Scaffold(
      appBar: AppBar(
        title: const Text('PAY 10% TOKEN'),
        // Tester 12-Oct: a way out — the order waits in My Orders.
        leading: IconButton(
          icon: const Icon(Icons.close_rounded),
          onPressed: () {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                content: Text('Your order is saved — pay the token any time from My Orders.')));
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
            const Text('Please pay a 10% token so we can process your order',
                textAlign: TextAlign.center, style: TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            Text(OrderService.formatRupees(due),
                style: const TextStyle(fontSize: 34, fontWeight: FontWeight.w900, color: green)),
            Text('of approx ${OrderService.formatRupees(o.approxTotal ?? 0)} · it will be deducted from your final bill',
                style: const TextStyle(color: Colors.black54)),
          ]),
        ),
        const SizedBox(height: 18),
        // Owner 13-Oct: the QR, big and clear; any UPI app can pay it.
        Text('SCAN THIS QR & PAY ${OrderService.formatRupees(due)}',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
        const SizedBox(height: 4),
        const Text('Google Pay · PhonePe · Paytm · BHIM · any UPI app',
            textAlign: TextAlign.center, style: TextStyle(color: Colors.black54)),
        const SizedBox(height: 10),
        // Owner 13-Oct: the shop's own HDFC QR with the amount written in — scan, Pay.
        LayoutBuilder(
          builder: (_, c) => Center(
            child: RepaintBoundary(
              child: Container(
                width: c.maxWidth.clamp(240.0, 380.0),
                padding: const EdgeInsets.fromLTRB(18, 14, 18, 14),
                decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: const Color(0xFF0B2C7A), width: 2)),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  const Text('B B SYNTHETICS',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: Color(0xFF0B2C7A))),
                  const SizedBox(height: 8),
                  QrImageView(
                    data: UpiQr.withAmount(due),
                    backgroundColor: Colors.white,
                    errorCorrectionLevel: QrErrorCorrectLevel.M,
                    padding: const EdgeInsets.all(6),
                  ),
                  const SizedBox(height: 6),
                  Text('Amount ${OrderService.formatRupees(due)} — filled in when you scan',
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontWeight: FontWeight.w800, color: Color(0xFF1B8E3A))),
                ]),
              ),
            ),
          ),
        ),
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
            label: Text(_busy ? 'CHECKING PAYMENT…' : 'SHARE PAYMENT SCREENSHOT',
                style: const TextStyle(fontWeight: FontWeight.w900)),
          ),
        ),
      ]),
    ),
    );
  }
}
