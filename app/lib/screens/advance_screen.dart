import 'dart:convert';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:gal/gal.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:url_launcher/url_launcher.dart';

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
  static const _upi = 'vyapar.173947529358@hdfcbank'; // QR + shown UPI id
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

  /// UPI apps, opened on their home screen (never a pay link — refused for
  /// a merchant id). iPhone + Android schemes, the first that opens wins.
  static const _apps = [
    (name: 'PhonePe', urls: ['phonepe://'], color: Color(0xFF5F259F)),
    (name: 'Google Pay', urls: ['gpay://', 'tez://upi/'], color: Color(0xFF1A73E8)),
    (name: 'Paytm', urls: ['paytmmp://', 'paytm://'], color: Color(0xFF00B9F1)),
    (name: 'BHIM', urls: ['bhim://'], color: Color(0xFFF47C20)),
  ];

  Future<void> _payWithApp(int due) async {
    await Clipboard.setData(const ClipboardData(text: _upi));
    if (!mounted) return;
    final pick = await showModalBottomSheet<List<String>>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('✅ UPI ID copied — pay ${OrderService.formatRupees(due)}',
                style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w900)),
            const SizedBox(height: 6),
            Text('In the app tap "To UPI ID" (PhonePe) / "Pay UPI ID" (Google Pay) → PASTE → '
                'the name must be B B SYNTHETICS → enter ${OrderService.formatRupees(due)} → Pay.\n'
                'Then come back and upload the screenshot.',
                style: const TextStyle(height: 1.4)),
            const SizedBox(height: 8),
            for (final a in _apps)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: CircleAvatar(
                    backgroundColor: a.color,
                    child: Text(a.name[0], style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w900))),
                title: Text('Open ${a.name}', style: const TextStyle(fontWeight: FontWeight.w800)),
                trailing: const Icon(Icons.open_in_new_rounded),
                onTap: () => Navigator.pop(ctx, a.urls),
              ),
            // Owner 13-Oct: any bank's own app works the same way.
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const CircleAvatar(
                  backgroundColor: Color(0xFF004C8F),
                  child: Icon(Icons.account_balance_rounded, color: Colors.white)),
              title: const Text('My bank app (HDFC, Kotak, SBI, ICICI, Axis…)',
                  style: TextStyle(fontWeight: FontWeight.w800)),
              subtitle: const Text('Open it yourself → UPI → "Pay to UPI ID" → paste'),
              onTap: () => Navigator.pop(ctx, const <String>[]),
            ),
          ]),
        ),
      ),
    );
    if (pick == null || pick.isEmpty) return;
    for (final u in pick) {
      final ok = await launchUrl(Uri.parse(u), mode: LaunchMode.externalApplication).catchError((_) => false);
      if (ok) return;
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('That app is not on this phone — open your UPI app yourself; the UPI ID is copied.')));
    }
  }

  /// The QR as a picture: Save it (or share it to the UPI app), then in the
  /// UPI app "Scan QR" → gallery. Works even when a link is refused.
  final _qrKey = GlobalKey();

  Future<void> _shareQr() async {
    // The amount QR card on screen, as a picture (scan it from the gallery);
    // the shop's printed QR only if that fails.
    final box = context.findRenderObject() as RenderBox?;
    try {
      final f = File('${(await getTemporaryDirectory()).path}/BB_SYNTHETICS_UPI_QR.png');
      final rb = _qrKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
      final img = rb == null ? null : await rb.toImage(pixelRatio: 3);
      final png = img == null ? null : await img.toByteData(format: ui.ImageByteFormat.png);
      if (png != null) {
        await f.writeAsBytes(png.buffer.asUint8List(), flush: true);
        // Review 13-Oct: straight into the photo gallery — the share sheet
        // has no "save" on many Android phones.
        try {
          await Gal.putImage(f.path, album: 'AKN Zone');
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                content: Text('QR saved in your photos — in your UPI app tap Scan → Gallery.')));
          }
          return;
        } catch (_) {/* fall back to the share sheet */}
      } else {
        await f.writeAsBytes(await (await DefaultCacheManager().getSingleFile(_qr)).readAsBytes(), flush: true);
      }
      await Share.shareXFiles([XFile(f.path, mimeType: 'image/png')],
          text: 'B.B SYNTHETICS — UPI QR',
          sharePositionOrigin: box == null ? null : box.localToGlobal(Offset.zero) & box.size);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Could not save the QR — take a screenshot of it instead, then Scan → Gallery in your UPI app.')));
      }
    }
  }


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
        const SizedBox(height: 14),
        SizedBox(
          height: 54,
          child: FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: green),
            onPressed: () => _payWithApp(due),
            icon: const Icon(Icons.account_balance_wallet_rounded),
            label: Text('PAY ${OrderService.formatRupees(due)} WITH UPI APP',
                style: const TextStyle(fontWeight: FontWeight.w900)),
          ),
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
              key: _qrKey,
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
        const SizedBox(height: 6),
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: const Text('Amount QR not working? Use the shop QR (type the amount yourself)',
              style: TextStyle(fontSize: 13)),
          children: [
            Center(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: CachedNetworkImage(imageUrl: _qr, width: 260, fit: BoxFit.contain),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        const Text('Paying from this same phone? Save the QR, then in your UPI app tap Scan → Gallery.',
            textAlign: TextAlign.center, style: TextStyle(color: Colors.black54)),
        const SizedBox(height: 6),
        Center(
          child: OutlinedButton.icon(
            onPressed: _shareQr,
            icon: const Icon(Icons.download_rounded),
            label: const Text('SAVE QR'),
          ),
        ),
        const SizedBox(height: 18),
        // Owner 13-Oct: paying by typing the UPI ID works in every UPI app
        // (a link from our app is refused — merchant id, no payment gateway).
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: green.withValues(alpha: 0.5))),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('OR PAY ${OrderService.formatRupees(due)} TO THIS UPI ID',
                style: const TextStyle(fontWeight: FontWeight.w900)),
            const SizedBox(height: 8),
            Row(children: [
              const Expanded(
                child: SelectableText(_upi,
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
              ),
              FilledButton.icon(
                style: FilledButton.styleFrom(backgroundColor: green),
                onPressed: () => _copy(_upi, 'UPI ID'),
                icon: const Icon(Icons.copy_rounded, size: 18),
                label: const Text('COPY'),
              ),
            ]),
            const SizedBox(height: 8),
            Text('1. Open any UPI app (PhonePe, Google Pay, Paytm, your bank app) → "Pay to UPI ID".\n'
                '2. Paste the UPI ID, enter ${OrderService.formatRupees(due)} — the name shown must be B B SYNTHETICS.\n'
                '3. Pay, take a screenshot and upload it below.',
                style: const TextStyle(color: Colors.black87, height: 1.4)),
          ]),
        ),
        const SizedBox(height: 16),
        // Owner 13-Oct: HDFC only (QR / UPI id) — no bank transfer, no Kotak.
        const Text('⚠️ The name must always be B B SYNTHETICS (HDFC). If any other name shows, it is not our account — do not pay.',
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
            label: Text(_busy ? 'CHECKING PAYMENT…' : 'UPLOAD PAYMENT SCREENSHOT(S)',
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
