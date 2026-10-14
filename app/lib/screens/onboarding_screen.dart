import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:catalog_app/widgets/caps_text.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import '../config.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:flutter/services.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/account_service.dart';
import '../services/chat_service.dart';
import '../services/id_check.dart';
import '../services/order_service.dart';
import '../services/push_service.dart';
import '../services/transport_info.dart';
import '../theme.dart';

const _green = Color(0xFF1B8E3A);
const _dark = Color(0xFF1B1A18);
const _red = Color(0xFFD32F2F);

final _gstRe = RegExp(r'^\d{2}[A-Z]{5}\d{4}[A-Z][0-9A-Z]Z[0-9A-Z]$');
final _panRe = RegExp(r'^[A-Z]{5}\d{4}[A-Z]$');
final _aadhaarRe = RegExp(r'^[2-9]\d{11}$');

/// "+91 98xxxxxxxx" for an Indian number, "+<digits>" for a foreign one.
String _shownMobile(String raw, bool india) {
  if (india) {
    final m = OrderService.normalizeIndianMobile(raw);
    if (m != null) return '+91 $m';
  }
  final d = raw.replaceAll(RegExp(r'\D'), '');
  return d.isEmpty ? raw : '+$d';
}

Future<void> _openShopChat() async {
  try {
    await launchUrl(AccountService.chatLink(), mode: LaunchMode.externalApplication);
  } catch (_) {}
}

/// Big full-width button used on every onboarding screen.
class _BigButton extends StatelessWidget {
  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final Color color;
  final bool busy;
  const _BigButton(
      {required this.label, this.icon, this.onPressed, this.color = _dark, this.busy = false});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: FilledButton.icon(
        style: FilledButton.styleFrom(
          backgroundColor: color,
          foregroundColor: Colors.white,
          minimumSize: const Size.fromHeight(54),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
        onPressed: busy ? null : onPressed,
        icon: busy
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
            : Icon(icon ?? Icons.arrow_forward_rounded, size: 22),
        label: UText(label,
            textAlign: TextAlign.center,
            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15, letterSpacing: 0.6)),
      ),
    );
  }
}

class _Wordmark extends StatelessWidget {
  const _Wordmark();
  @override
  Widget build(BuildContext context) => const UText(
        'AKN Zone',
        textAlign: TextAlign.center,
        style: TextStyle(
            fontFamily: 'Playfair',
            fontSize: 26,
            fontWeight: FontWeight.w700,
            letterSpacing: 2.0,
            color: kInk),
      );
}

/// Scrollable, centred page body that never overflows on a small phone.
class _Page extends StatelessWidget {
  final List<Widget> children;
  final PreferredSizeWidget? appBar;
  const _Page({required this.children, this.appBar});
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: appBar,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(22, 20, 22, 28),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: children,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// ============================================================
/// ACCESS REMOVED / NOT APPROVED (owner 14-Oct)
/// ============================================================
class AccountRemovedScreen extends StatelessWidget {
  final bool declined;
  final VoidCallback onRetry;
  const AccountRemovedScreen({super.key, required this.declined, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return _Page(children: [
      const _Wordmark(),
      const SizedBox(height: 30),
      Icon(declined ? Icons.block_rounded : Icons.lock_outline_rounded, size: 64, color: _red),
      const SizedBox(height: 18),
      UText(declined ? 'Not approved' : 'Access removed',
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: _dark)),
      const SizedBox(height: 10),
      Text(
        declined
            ? 'Your account was not approved. Please contact AKN Zone.'
            : 'Your access to the AKN Zone catalog has been removed. Please contact AKN Zone.',
        textAlign: TextAlign.center,
        style: const TextStyle(fontSize: 15, height: 1.5),
      ),
      const SizedBox(height: 28),
      const _BigButton(
          label: 'Chat on WhatsApp', icon: Icons.chat_rounded, color: _green, onPressed: _openShopChat),
      const SizedBox(height: 10),
      OutlinedButton.icon(
        style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(50)),
        onPressed: onRetry,
        icon: const Icon(Icons.refresh_rounded),
        label: const UText('Check again'),
      ),
    ]);
  }
}

/// ============================================================
/// ONBOARDING — WhatsApp verify → claim / sign up → approval
/// ============================================================
class OnboardingFlow extends StatefulWidget {
  /// Called when the saved account changed (approved / blocked / declined) —
  /// the gate then decides what to show.
  final VoidCallback onDone;
  const OnboardingFlow({super.key, required this.onDone});

  @override
  State<OnboardingFlow> createState() => _OnboardingFlowState();
}

enum _Step { phone, waiting, mismatch, pick, form, pending }

class _OnboardingFlowState extends State<OnboardingFlow> with WidgetsBindingObserver {
  SharedPreferences? _prefs;
  bool _ready = false;
  _Step _step = _Step.phone;

  // 1. number
  String _country = 'India';
  final _phone = TextEditingController();
  String? _phoneErr;

  // 2. waiting for the WhatsApp message
  String? _code;
  String _typed = ''; // the number typed (normalized)
  Map<String, dynamic>? _held; // verified, but from another number than typed
  bool _mismatchOk = false;
  Timer? _poll;
  DateTime? _pollStart;
  bool _checking = false;
  bool _timedOut = false;
  String? _waitMsg;

  // 3. verified
  String _vMobile = '';
  bool _vIndia = true;
  bool _mismatch = false;
  List<Map<String, dynamic>> _parties = const [];
  String? _claiming;
  String? _pickErr;

  // 4. pending approval
  Timer? _pendTimer;
  bool _pendChecking = false;
  String? _pendMsg;

  bool get _india => _country == 'India';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _init();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _poll?.cancel();
    _pendTimer?.cancel();
    _phone.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s != AppLifecycleState.resumed) return;
    // Back from WhatsApp → check at once; back to the pending screen → ask
    // the shop's answer at once.
    if (_step == _Step.waiting && !_timedOut) _checkNow();
    if (_step == _Step.pending) _checkPending();
  }

  Future<void> _init() async {
    try {
      final p = await SharedPreferences.getInstance();
      _prefs = p;
      final a = AccountService.saved(p);
      if (a != null && a['status'] == 'pending') {
        _vMobile = '${a['mobile'] ?? ''}';
        _vIndia = a['india'] != false;
        _step = _Step.pending;
        _startPending();
      } else {
        final c = AccountService.savedCode(p);
        if (c != null) {
          // The app was closed while the customer was in WhatsApp — carry on.
          _code = c.code;
          _typed = c.mobile;
          _country = OrderService.countries.contains(c.country) ? c.country : 'India';
          _phone.text = _india ? (OrderService.normalizeIndianMobile(c.mobile) ?? '') : c.mobile;
          _step = _Step.waiting;
          _startPolling(c.at);
        }
      }
    } catch (_) {}
    if (mounted) setState(() => _ready = true);
  }

  // ───────────────────────── 1 → 2: send the code ─────────────────────────

  Future<void> _verify() async {
    FocusScope.of(context).unfocus();
    const m = ''; // the number comes from WhatsApp itself
    final code = AccountService.newCode();
    setState(() {
      _phoneErr = null;
      _typed = m;
      _code = code;
      _waitMsg = null;
      _timedOut = false;
      _step = _Step.waiting;
    });
    try {
      final p = _prefs ?? await SharedPreferences.getInstance();
      await AccountService.saveCode(p, code: code, mobile: m, country: _country);
    } catch (_) {}
    _startPolling(DateTime.now());
    await _openWhatsApp();
  }

  Future<void> _openWhatsApp() async {
    final code = _code;
    if (code == null) return;
    var ok = false;
    try {
      ok = await launchUrl(AccountService.whatsAppLink(code), mode: LaunchMode.externalApplication);
    } catch (_) {}
    if (!ok && mounted) {
      setState(() => _waitMsg =
          'WhatsApp could not be opened. Please install WhatsApp, or send "AKN LOGIN $code" '
          'to +91 70166 38059 on WhatsApp.');
    }
  }

  void _startPolling(DateTime from) {
    _poll?.cancel();
    _pollStart = from;
    _poll = Timer.periodic(const Duration(seconds: 3), (_) => _checkNow());
  }

  Future<void> _checkNow({bool manual = false}) async {
    final code = _code;
    if (code == null || _checking || _step != _Step.waiting) return;
    if (_pollStart != null && DateTime.now().difference(_pollStart!) > const Duration(minutes: 10)) {
      _poll?.cancel();
      if (mounted) setState(() => _timedOut = true);
      if (!manual) return;
    }
    _checking = true;
    if (manual && mounted) setState(() {});
    try {
      final d = await AccountService.verify(code);
      if (!mounted || _code != code || _step != _Step.waiting) return;
      if (d == null) {
        if (manual) setState(() => _waitMsg = 'No internet — please check your connection and try again.');
        return;
      }
      if (d['verified'] == true) {
        _poll?.cancel();
        await _onVerified(d);
        return;
      }
      if (manual) {
        setState(() => _waitMsg =
            'Not received yet. In WhatsApp, tap SEND on the "AKN LOGIN $code" message, then come back.');
      }
    } catch (_) {
    } finally {
      _checking = false;
      if (mounted && manual) setState(() {});
    }
  }

  void _changeNumber() {
    _poll?.cancel();
    _pendTimer?.cancel();
    final p = _prefs;
    if (p != null) {
      // ignore: discarded_futures
      AccountService.clear(p);
    }
    setState(() {
      _code = null;
      _waitMsg = null;
      _timedOut = false;
      _parties = const [];
      _pickErr = null;
      _pendMsg = null;
      _step = _Step.phone;
    });
  }

  // ───────────────────────── verified ─────────────────────────

  Map<String, dynamic> _accountFrom(Map d, String status) => {
        'mobile': _vMobile,
        'india': _vIndia,
        'status': status,
        'kind': d['kind'],
        'party': d['party'],
        'cust': d['cust'],
      };

  Future<void> _onVerified(Map<String, dynamic> d) async {
    final p = _prefs ?? await SharedPreferences.getInstance();
    _vMobile = '${d['mobile'] ?? _typed}';
    _vIndia = d['india'] != false;
    final a = ChatService.key(_typed), b = ChatService.key(_vMobile);
    _mismatch = a != null && b != null && a != b;
    if (_mismatch && !_mismatchOk) {
      _held = d;
      if (mounted) setState(() => _step = _Step.mismatch);
      return;
    }
    final status = '${d['status'] ?? 'none'}';
    switch (status) {
      case 'approved':
        await AccountService.approve(p, _accountFrom(d, 'approved'));
        widget.onDone();
        return;
      case 'blocked':
      case 'declined':
        await AccountService.save(p, _accountFrom(d, status));
        await AccountService.clearCode(p);
        widget.onDone();
        return;
      case 'pending':
        await AccountService.save(p, _accountFrom(d, 'pending'));
        if (!mounted) return;
        setState(() => _step = _Step.pending);
        _startPending();
        return;
    }
    final parties = <Map<String, dynamic>>[
      for (final x in (d['parties'] as List? ?? const []))
        if (x is Map) Map<String, dynamic>.from(x),
    ];
    if (!mounted) return;
    setState(() {
      _parties = parties;
      _step = parties.isNotEmpty ? _Step.pick : _Step.form;
    });
  }

  /// The verified number, shown when it differs from the typed one.
  Widget _mismatchNote() {
    if (!_mismatch) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF4E5),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFFFB74D)),
      ),
      child: Text(
        'Verified number: ${_shownMobile(_vMobile, _vIndia)}\n'
        '(the WhatsApp message came from this number, not ${_shownMobile(_typed, _india)}).',
        style: const TextStyle(fontWeight: FontWeight.w700, height: 1.4),
      ),
    );
  }

  // ───────────────────────── existing customer ─────────────────────────

  Future<void> _claim(Map<String, dynamic> pt) async {
    final code = _code;
    final name = '${pt['name'] ?? ''}';
    if (code == null || name.isEmpty || _claiming != null) return;
    setState(() {
      _claiming = name;
      _pickErr = null;
    });
    try {
      final d = await AccountService.claim(code, name);
      if (!mounted) return;
      if (d == null) {
        setState(() => _pickErr = 'No internet — please try again.');
        return;
      }
      if (d['ok'] != true) {
        setState(() => _pickErr = '${d['error'] ?? 'Could not select this account. Please try again.'}');
        return;
      }
      String v(String k) => '${pt[k] ?? ''}'.trim();
      final account = <String, dynamic>{
        'mobile': _vMobile,
        'india': _vIndia,
        'status': '${d['status'] ?? 'pending'}',
        'kind': 'existing',
        'party': name,
        'cust': {
          'billName': name,
          'address': v('address'),
          'pincode': v('pincode'),
          'bookingPlace': v('dest'),
          'transport': v('transport'),
          'taxId': v('gstin'),
          'country': _vIndia ? 'India' : (_india ? 'Other' : _country),
        },
      };
      await _afterSubmit(account);
    } finally {
      if (mounted) setState(() => _claiming = null);
    }
  }

  /// accountClaim / accountSignup answered → approved enters the app,
  /// blocked shows the removed screen, pending waits for the shop.
  Future<void> _afterSubmit(Map<String, dynamic> account) async {
    final p = _prefs ?? await SharedPreferences.getInstance();
    final status = '${account['status']}';
    if (status == 'approved') {
      await AccountService.approve(p, account);
      widget.onDone();
      return;
    }
    await AccountService.save(p, account);
    if (status == 'blocked' || status == 'declined') {
      await AccountService.clearCode(p);
      widget.onDone();
      return;
    }
    await AccountService.clearCode(p);
    if (!mounted) return;
    setState(() => _step = _Step.pending);
    _startPending();
  }

  // ───────────────────────── pending approval ─────────────────────────

  void _startPending() {
    _pendTimer?.cancel();
    _pendTimer = Timer.periodic(const Duration(seconds: 20), (_) => _checkPending());
    // So the approval push reaches this phone (the account's number).
    final p = _prefs;
    if (p != null) {
      // ignore: discarded_futures
      PushService.register(p, AccountService.dio);
    }
  }

  Future<void> _checkPending({bool manual = false}) async {
    if (_pendChecking) return;
    _pendChecking = true;
    if (manual && mounted) setState(() {});
    try {
      final p = _prefs ?? await SharedPreferences.getInstance();
      final a = AccountService.saved(p);
      final mobile = '${a?['mobile'] ?? _vMobile}';
      if (mobile.isEmpty) return;
      final d = await AccountService.checkStatus(mobile);
      if (!mounted || _step != _Step.pending) return;
      if (d == null) {
        if (manual) setState(() => _pendMsg = 'No internet — will check again by itself.');
        return;
      }
      final status = '${d['status'] ?? ''}';
      final merged = <String, dynamic>{
        ...?a,
        'mobile': mobile,
        'status': status,
        if (d['kind'] != null) 'kind': d['kind'],
        if (d['party'] != null) 'party': d['party'],
        if (d['cust'] is Map) 'cust': d['cust'],
      };
      switch (status) {
        case 'approved':
          _pendTimer?.cancel();
          await AccountService.approve(p, merged);
          widget.onDone();
          return;
        case 'blocked':
        case 'declined':
          _pendTimer?.cancel();
          await AccountService.save(p, merged);
          widget.onDone();
          return;
        case 'none':
          // The shop has no request for this number any more — start again.
          _pendTimer?.cancel();
          await AccountService.clear(p);
          if (!mounted) return;
          setState(() {
            _step = _Step.phone;
            _phoneErr = 'Your request was not found. Please verify your number again.';
          });
          return;
      }
      if (manual) setState(() => _pendMsg = 'Still waiting for approval — checked just now.');
    } catch (_) {
    } finally {
      _pendChecking = false;
      if (mounted && manual) setState(() {});
    }
  }

  // ───────────────────────── screens ─────────────────────────

  @override
  Widget build(BuildContext context) {
    if (!_ready) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    switch (_step) {
      case _Step.phone:
        return _phoneScreen();
      case _Step.waiting:
        return _waitingScreen();
      case _Step.mismatch:
        return _mismatchScreen();
      case _Step.pick:
        return _pickScreen();
      case _Step.form:
        return _SignupForm(
          code: _code ?? '',
          prefs: _prefs,
          india: _vIndia,
          country: _vIndia ? 'India' : (_india ? 'Other' : _country),
          header: _mismatchNote(),
          abroad: _abroad,
          mobileLabel: _abroad ? '' : _shownMobile(_vMobile, _vIndia),
          onBack: _abroad
              ? () => setState(() {
                    _abroad = false;
                    _step = _Step.phone;
                  })
              : (_parties.isNotEmpty ? () => setState(() => _step = _Step.pick) : _changeNumber),
          onResult: (status, cust) => _afterSubmit({
            'mobile': _abroad ? '${cust['mobile'] ?? ''}' : _vMobile,
            'india': _vIndia,
            'status': status,
            'kind': 'new',
            'party': null,
            'cust': cust,
          }),
        );
      case _Step.pending:
        return _pendingScreen();
    }
  }

  /// Typed number != the number whose WhatsApp sent the code.
  Widget _mismatchScreen() {
    final sent = _shownMobile(_vMobile, _vIndia);
    return _Page(children: [
      const _Wordmark(),
      const SizedBox(height: 26),
      const Icon(Icons.phonelink_lock_rounded, size: 56, color: _red),
      const SizedBox(height: 12),
      const Text('Number does not match',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: _dark)),
      const SizedBox(height: 10),
      Text(
        'You typed ${_shownMobile(_typed, _india)}, but the WhatsApp message was sent from $sent.\n\n'
        'For safety the app opens only for the number whose WhatsApp sent the message.',
        textAlign: TextAlign.center,
        style: const TextStyle(fontSize: 15, height: 1.5),
      ),
      const SizedBox(height: 24),
      _BigButton(
        label: 'Continue as $sent',
        icon: Icons.check_circle_rounded,
        color: _green,
        onPressed: () {
          final d = _held;
          if (d == null) return;
          _mismatchOk = true;
          // ignore: discarded_futures
          _onVerified(d);
        },
      ),
      const SizedBox(height: 12),
      TextButton(
        onPressed: () {
          _held = null;
          _mismatchOk = false;
          _changeNumber();
        },
        child: const UText('Use another number'),
      ),
    ]);
  }

  /// Owner 14-Oct: network location — 'IN', another code, or null (unknown).
  String? _netCountry;
  bool _abroad = false;

  Future<void> _checkNetCountry() async {
    try {
      final r = await AccountService.dio.get<String>('https://www.cloudflare.com/cdn-cgi/trace',
          options: Options(receiveTimeout: const Duration(seconds: 5), sendTimeout: const Duration(seconds: 5)));
      final m = RegExp(r'^loc=([A-Z]{2})$', multiLine: true).firstMatch(r.data ?? '');
      if (m != null && mounted) setState(() => _netCountry = m.group(1));
    } catch (_) {}
  }

  Widget _phoneScreen() {
    if (_netCountry == null) {
      // ignore: discarded_futures
      _checkNetCountry();
    }
    return _Page(children: [
      const _Wordmark(),
      const SizedBox(height: 26),
      const Text('Welcome to AKN Zone',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: _dark)),
      const SizedBox(height: 8),
      const Text('Log in with your WhatsApp — no number to type.',
          textAlign: TextAlign.center, style: TextStyle(fontSize: 15, height: 1.4)),
      const SizedBox(height: 22),
      _BigButton(
          label: 'Login with WhatsApp', icon: Icons.chat_rounded, color: _green, onPressed: _verify),
      if (_netCountry != null && _netCountry != 'IN') ...[
        const SizedBox(height: 18),
        const Text('Outside India? No login needed.',
            textAlign: TextAlign.center, style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(52)),
          onPressed: () => setState(() {
            _abroad = true;
            _vIndia = false;
            _country = 'Other';
            _step = _Step.form;
          }),
          icon: const Icon(Icons.public_rounded),
          label: const UText('Continue — I am outside India'),
        ),
      ],
      const SizedBox(height: 12),
      const Text(
        'WhatsApp opens with a message ready — just tap SEND and come back to this app.',
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 13, color: Colors.black54, height: 1.4),
      ),
      TextButton(
        onPressed: () => launchUrl(Uri.parse(kPrivacyUrl), mode: LaunchMode.externalApplication),
        child: const Text('Privacy policy', style: TextStyle(fontSize: 12.5)),
      ),
    ]);
  }

  Widget _waitingScreen() {
    final code = _code ?? '';
    return _Page(children: [
      const _Wordmark(),
      const SizedBox(height: 28),
      if (!_timedOut)
        const Center(
            child: SizedBox(
                width: 46, height: 46, child: CircularProgressIndicator(strokeWidth: 4, color: _green)))
      else
        const Icon(Icons.timer_off_outlined, size: 52, color: _red),
      const SizedBox(height: 20),
      Text(_timedOut ? 'Time is up' : 'Waiting for your WhatsApp message',
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: _dark)),
      const SizedBox(height: 10),
      Text(
        _timedOut
            ? 'We did not receive the message. Tap SEND A NEW CODE to try again.'
            : 'In WhatsApp, tap SEND on the message "AKN LOGIN $code". '
                'This screen moves on by itself once it is received.',
        textAlign: TextAlign.center,
        style: const TextStyle(fontSize: 15, height: 1.45),
      ),
      if (!_timedOut && code.isNotEmpty) ...[
        const SizedBox(height: 16),
        Center(
          child: Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: kHairline),
            ),
            child: QrImageView(
                data: AccountService.whatsAppLink(code).toString(), size: 150, padding: EdgeInsets.zero),
          ),
        ),
        const SizedBox(height: 8),
        Text('Code: $code',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900, letterSpacing: 2, color: _dark)),
        const SizedBox(height: 6),
        const Text(
          'Using an iPad or another phone? Scan this QR with the phone that has WhatsApp and tap SEND there.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 13, color: Colors.black54, height: 1.45),
        ),
      ],
      const SizedBox(height: 8),
      if (_typed.isNotEmpty)
      Text('Number: ${_shownMobile(_typed, _india)}',
          textAlign: TextAlign.center,
          style: const TextStyle(fontWeight: FontWeight.w700, color: Colors.black54)),
      if (_waitMsg != null) ...[
        const SizedBox(height: 12),
        Text(_waitMsg!,
            textAlign: TextAlign.center,
            style: const TextStyle(color: _red, fontWeight: FontWeight.w700, height: 1.4)),
      ],
      const SizedBox(height: 24),
      if (_timedOut)
        _BigButton(
            label: 'Send a new code', icon: Icons.chat_rounded, color: _green, onPressed: _verify)
      else ...[
        _BigButton(
            label: 'Open WhatsApp again',
            icon: Icons.chat_rounded,
            color: _green,
            onPressed: _openWhatsApp),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(50)),
          onPressed: _checking ? null : () => _checkNow(manual: true),
          icon: _checking
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.done_all_rounded),
          label: const UText("I've sent it — check"),
        ),
      ],
      const SizedBox(height: 6),
      TextButton(onPressed: _changeNumber, child: const UText('Start again')),
    ]);
  }

  Widget _partyTile(Map<String, dynamic> pt) {
    String v(String k) => '${pt[k] ?? ''}'.trim();
    final lines = <String>[
      if (v('address').isNotEmpty) v('address'),
      [v('dest'), v('pincode')].where((s) => s.isNotEmpty).join(' - '),
    ].where((s) => s.isNotEmpty).toList();
    final busy = _claiming == v('name');
    return Card(
      margin: const EdgeInsets.only(top: 10),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: kHairline),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: _claiming != null ? null : () => _claim(pt),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Padding(
              padding: EdgeInsets.only(top: 2),
              child: Icon(Icons.storefront_rounded, color: _green),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(v('name'),
                    style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16, color: _dark)),
                if (lines.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(lines.join('\n'), style: const TextStyle(height: 1.35)),
                ],
              ]),
            ),
            const SizedBox(width: 8),
            busy
                ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.chevron_right_rounded),
          ]),
        ),
      ),
    );
  }

  Widget _pickScreen() {
    return _Page(children: [
      const _Wordmark(),
      const SizedBox(height: 22),
      _mismatchNote(),
      const Text('✓ Number verified',
          textAlign: TextAlign.center,
          style: TextStyle(color: _green, fontWeight: FontWeight.w800, fontSize: 15)),
      const SizedBox(height: 6),
      const Text('Select your account',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: _dark)),
      const SizedBox(height: 6),
      Text(
        _parties.length == 1
            ? 'This number is already with us. Tap your account to continue.'
            : 'This number has ${_parties.length} accounts with us. Tap yours to continue.',
        textAlign: TextAlign.center,
        style: const TextStyle(fontSize: 14, height: 1.4),
      ),
      const SizedBox(height: 6),
      for (final pt in _parties) _partyTile(pt),
      if (_pickErr != null) ...[
        const SizedBox(height: 12),
        Text(_pickErr!,
            textAlign: TextAlign.center,
            style: const TextStyle(color: _red, fontWeight: FontWeight.w700)),
      ],
      const SizedBox(height: 18),
      TextButton(
        onPressed: _claiming != null ? null : () => setState(() => _step = _Step.form),
        child: const Text('My account is not in this list — sign up as a new customer',
            textAlign: TextAlign.center),
      ),
      TextButton(onPressed: _changeNumber, child: const UText('Start again')),
    ]);
  }

  Widget _pendingScreen() {
    return Scaffold(
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: () => _checkPending(manual: true),
          child: LayoutBuilder(
            builder: (context, box) => SingleChildScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(22, 20, 22, 28),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                    minHeight: box.maxHeight.isFinite && box.maxHeight > 48 ? box.maxHeight - 48 : 0),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 440),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const _Wordmark(),
                        const SizedBox(height: 28),
                        const Icon(Icons.hourglass_top_rounded, size: 60, color: _green),
                        const SizedBox(height: 18),
                        const Text('Waiting for approval',
                            textAlign: TextAlign.center,
                            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: _dark)),
                        const SizedBox(height: 10),
                        const Text(
                          'Thank you! AKN Zone is checking your details. We will notify you as soon '
                          'as your account is approved — the catalog then opens by itself.',
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 15, height: 1.5),
                        ),
                        if (_vMobile.isNotEmpty) ...[
                          const SizedBox(height: 10),
                          Text('Number: ${_shownMobile(_vMobile, _vIndia)}',
                              textAlign: TextAlign.center,
                              style: const TextStyle(fontWeight: FontWeight.w700, color: Colors.black54)),
                        ],
                        if (_pendMsg != null) ...[
                          const SizedBox(height: 10),
                          Text(_pendMsg!,
                              textAlign: TextAlign.center,
                              style: const TextStyle(fontSize: 13, color: Colors.black54)),
                        ],
                        const SizedBox(height: 26),
                        _BigButton(
                          label: 'Check now',
                          icon: Icons.refresh_rounded,
                          busy: _pendChecking,
                          onPressed: () => _checkPending(manual: true),
                        ),
                        const SizedBox(height: 6),
                        TextButton(onPressed: _changeNumber, child: const UText('Start again')),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// ============================================================
/// SIGN-UP FORM (owner 14-Oct) — India: full details + GST, else PAN +
/// photo, else Aadhaar + photo. Abroad: name, address, city, country.
/// ============================================================
class _SignupForm extends StatefulWidget {
  final String code;
  final SharedPreferences? prefs;
  final bool india;
  final String country;
  final Widget header;
  final String mobileLabel;
  final VoidCallback onBack;

  /// Owner 14-Oct: customer abroad, no WhatsApp login — the form asks the
  /// mobile number (with country code) and the cloud approves at once.
  final bool abroad;

  /// accountSignup's status + the details sent (without the photo).
  final Future<void> Function(String status, Map<String, dynamic> cust) onResult;
  const _SignupForm({
    required this.code,
    required this.prefs,
    required this.india,
    required this.country,
    required this.header,
    required this.mobileLabel,
    required this.onBack,
    required this.onResult,
    this.abroad = false,
  });

  @override
  State<_SignupForm> createState() => _SignupFormState();
}

class _KycPhoto {
  final Uint8List jpg;
  final String text;
  const _KycPhoto(this.jpg, this.text);
}

class _SignupFormState extends State<_SignupForm> {
  final _formKey = GlobalKey<FormState>();
  final _contact = TextEditingController();
  final _bill = TextEditingController();
  final _address = TextEditingController();
  final _pin = TextEditingController();
  final _place = TextEditingController();
  final _transport = TextEditingController();
  final _transportFocus = FocusNode();
  final _gst = TextEditingController();
  final _mobileAbroad = TextEditingController();
  final _pan = TextEditingController();
  final _aadhaar = TextEditingController();
  late String _country = widget.country;

  _KycPhoto? _panPhoto;
  _KycPhoto? _aadhaarPhoto;
  _KycPhoto? _cardPhoto; // shop / visiting card (existing business, no GST)

  /// Owner 14-Oct: an existing saree business without GST shows its card.
  bool get _needCard => _india && !_hasGst && _businessType == 'existing_business';
  bool _reading = false;
  String? _photoErr;

  // GST check (like the order form).
  String? _gstNote;
  bool _gstOk = false;
  bool _gstChecking = false;
  String? _gstLooked;

  // Pincode check.
  PincodeInfo? _pinInfo;
  bool _pinChecking = false;
  bool _pinNotFound = false;
  Timer? _pinDebounce;

  List<String> _transports = const [];
  TransportInfo? _tInfo;

  bool _sending = false;
  String? _error;

  /// 'new_startup' | 'existing_business' (owner 14-Oct, required).
  String? _businessType;
  String? _bizErr;

  bool get _india => widget.india;

  @override
  void initState() {
    super.initState();
    if (_country == 'India' && !_india) _country = 'Other';
    _gst.addListener(_onGstTyped);
    _pan.addListener(_refresh);
    _gst.addListener(_refresh);
    _aadhaar.addListener(_refresh);
    _pin.addListener(_onPinChanged);
    _place.addListener(() => setState(() {}));
    _transport.addListener(() => setState(() {}));
    OrderService.transports().then((t) {
      if (mounted) setState(() => _transports = t);
    });
    final p = widget.prefs;
    if (p != null) {
      TransportInfo.load(p, AccountService.dio).then((i) {
        if (mounted) setState(() => _tInfo = i);
      }).catchError((_) {});
    }
  }

  @override
  void dispose() {
    _pinDebounce?.cancel();
    _gst.removeListener(_onGstTyped);
    _pan.removeListener(_refresh);
    _gst.removeListener(_refresh);
    _aadhaar.removeListener(_refresh);
    _pin.removeListener(_onPinChanged);
    for (final c in [_contact, _bill, _address, _pin, _place, _transport, _gst, _pan, _aadhaar]) {
      c.dispose();
    }
    _transportFocus.dispose();
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  String _norm(String s) => s.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');

  void _onGstTyped() {
    final g = _norm(_gst.text);
    if (gstValid(g)) {
      // ignore: discarded_futures
      _gstLookup(g);
    } else if (_gstNote != null || _gstLooked != null) {
      final was = _gstLooked;
      // GST removed -> drop the PAN it had filled in.
      if (was != null && was.length >= 12 && _norm(_pan.text) == was.substring(2, 12)) _pan.clear();
      setState(() {
        _gstNote = null;
        _gstLooked = null;
        _gstOk = false;
        _gstChecking = false;
      });
    }
  }

  /// Owner 14-Oct: same GST check as the order form — a verified GST fills
  /// bill name, address, pincode and city.
  Future<void> _gstLookup(String g) async {
    if (g == _gstLooked) return;
    _gstLooked = g;
    setState(() {
      _gstChecking = true;
      _gstOk = false;
      _gstNote = 'Checking GST number…';
    });
    final r = await OrderService.gstLookup(AccountService.dio, g);
    if (!mounted || _gstLooked != g) return;
    if (r == null || r['found'] != true) {
      setState(() {
        _gstChecking = false;
        _gstOk = false;
        _gstNote = '✗ This GST number could not be verified — correct it, or use PAN instead.';
      });
      return;
    }
    final status = '${r['status'] ?? ''}';
    final name = '${r['tradeName'] ?? ''}'.isNotEmpty ? '${r['tradeName']}' : '${r['legalName'] ?? ''}';
    setState(() {
      _gstChecking = false;
      if (name.isNotEmpty) _bill.text = name;
      _pan.text = g.substring(2, 12); // PAN is inside the GST number
      if ('${r['address'] ?? ''}'.isNotEmpty) _address.text = '${r['address']}';
      if ('${r['pin'] ?? ''}'.isNotEmpty) _pin.text = '${r['pin']}';
      if ('${r['city'] ?? ''}'.isNotEmpty && _place.text.trim().isEmpty) {
        _place.text = '${r['city']}';
      }
      _gstOk = status.toLowerCase() == 'active' || status.isEmpty;
      _gstNote = _gstOk
          ? '✓ GST verified — ${r['legalName'] ?? name}. Details filled; change anything if needed.'
          : '✗ This GST number is $status on the GST portal — correct it, or use PAN instead.';
    });
  }

  void _onPinChanged() {
    _pinDebounce?.cancel();
    final pin = _pin.text.trim();
    if (!_india || !RegExp(r'^[1-9]\d{5}$').hasMatch(pin)) {
      if (_pinInfo != null || _pinNotFound || _pinChecking) {
        setState(() {
          _pinInfo = null;
          _pinNotFound = false;
          _pinChecking = false;
        });
      }
      return;
    }
    _pinDebounce = Timer(const Duration(milliseconds: 350), () async {
      if (!mounted) return;
      setState(() => _pinChecking = true);
      try {
        final info = await OrderService.lookupPincode(AccountService.dio, pin);
        if (!mounted || _pin.text.trim() != pin) return;
        setState(() {
          _pinInfo = info;
          _pinNotFound = info == null;
          if (info != null && _place.text.trim().isEmpty) _place.text = info.district;
        });
      } catch (_) {
        // Offline: skip the check, never block the sign-up.
        if (mounted) {
          setState(() {
            _pinInfo = null;
            _pinNotFound = false;
          });
        }
      } finally {
        if (mounted) setState(() => _pinChecking = false);
      }
    });
  }

  // ───────────────────────── ID photo ─────────────────────────

  Future<void> _pickPhoto(bool aadhaar, {bool card = false}) async {
    FocusScope.of(context).unfocus();
    final src = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (c) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.photo_camera_rounded),
            title: const Text('Take a photo'),
            onTap: () => Navigator.pop(c, ImageSource.camera),
          ),
          ListTile(
            leading: const Icon(Icons.photo_library_rounded),
            title: const Text('Choose from gallery'),
            onTap: () => Navigator.pop(c, ImageSource.gallery),
          ),
        ]),
      ),
    );
    if (src == null || !mounted) return;
    setState(() {
      _reading = true;
      _photoErr = null;
    });
    try {
      final x = await ImagePicker()
          .pickImage(source: src, maxWidth: 1600, maxHeight: 1600, imageQuality: 80);
      if (x == null) return;
      var bytes = await x.readAsBytes();
      try {
        final jpg = await FlutterImageCompress.compressWithList(bytes,
            minWidth: 1600, minHeight: 1600, quality: 80, format: CompressFormat.jpeg);
        if (jpg.isNotEmpty) bytes = jpg;
      } catch (_) {}
      // Read the card on the phone (free) — sent with the photo.
      var text = '';
      try {
        final rec = TextRecognizer(script: TextRecognitionScript.latin);
        text = (await rec.processImage(InputImage.fromFilePath(x.path))).text;
        await rec.close();
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        final ph = _KycPhoto(bytes, text);
        if (card) {
          _cardPhoto = ph;
        } else if (aadhaar) {
          _aadhaarPhoto = ph;
          _aadhaar.text = _readAadhaar(text);
        } else {
          _panPhoto = ph;
          _pan.text = _readPan(text);
        }
      });
    } catch (_) {
      if (mounted) setState(() => _photoErr = 'Could not open the camera / gallery. Please try again.');
    } finally {
      if (mounted) setState(() => _reading = false);
    }
  }

  static String _readPan(String text) {
    final up = text.toUpperCase();
    final re = RegExp(r'[A-Z]{3}[PCHFATBLJG][A-Z]\d{4}[A-Z]');
    for (final t in up.split(RegExp(r'\s+'))) {
      final m = re.firstMatch(t.replaceAll(RegExp(r'[^A-Z0-9]'), ''));
      if (m != null) return m.group(0)!;
    }
    for (final line in up.split('\n')) {
      final m = re.firstMatch(line.replaceAll(RegExp(r'[^A-Z0-9]'), ''));
      if (m != null) return m.group(0)!;
    }
    return '';
  }

  static String _readAadhaar(String text) {
    for (final m in RegExp(r'(?<!\d)(\d{4})\s?(\d{4})\s?(\d{4})(?!\d)').allMatches(text)) {
      final n = '${m.group(1)}${m.group(2)}${m.group(3)}';
      if (aadhaarValid(n)) return n;
    }
    return '';
  }

  /// A valid GST number is filled in (it may still be checking).
  bool get _hasGst => gstValid(_gst.text);

  /// Which ID this sign-up uses: GST, else PAN, else Aadhaar.
  String get _idUsed {
    if (_hasGst) return 'gst';
    if (_panPhoto != null && panValid(_pan.text)) return 'pan';
    if (_aadhaarPhoto != null && aadhaarValid(_aadhaar.text)) return 'aadhaar';
    if (_panPhoto != null) return 'pan';
    if (_aadhaarPhoto != null) return 'aadhaar';
    return '';
  }

  /// PAN / Aadhaar card photo; the number is read from it on the phone.
  Widget _idPhoto({required bool aadhaar}) {
    final ph = aadhaar ? _aadhaarPhoto : _panPhoto;
    final num = aadhaar ? _aadhaar.text : _pan.text;
    final ok = aadhaar ? aadhaarValid(num) : panValid(num);
    final what = aadhaar ? 'Aadhaar card (side with your address)' : 'PAN card';
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (ph != null)
        ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Container(color: kLinen, height: 140, child: Image.memory(ph.jpg, fit: BoxFit.contain)),
        ),
      if (ph != null)
        Padding(
          padding: const EdgeInsets.only(top: 4, left: 4),
          child: Text(
              ok
                  ? '✓ ${aadhaar ? 'Aadhaar' : 'PAN'} number read: ${aadhaar ? 'XXXX XXXX ${num.substring(num.length - 4)}' : num}'
                  : '✗ Could not read the ${aadhaar ? 'Aadhaar' : 'PAN'} number — take a clear, straight photo',
              style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12.5, color: ok ? _green : _red)),
        ),
      const SizedBox(height: 6),
      OutlinedButton.icon(
        style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(50)),
        onPressed: _reading ? null : () => _pickPhoto(aadhaar),
        icon: _reading
            ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
            : Icon(ph == null ? Icons.add_a_photo_rounded : Icons.cameraswitch_rounded),
        label: Text(ph == null ? 'Add photo of your $what' : 'Change ${aadhaar ? 'Aadhaar' : 'PAN'} photo',
            textAlign: TextAlign.center),
      ),
    ]);
  }

  // ───────────────────────── submit ─────────────────────────

  String? _idError() {
    if (!_india) return null;
    final g = _norm(_gst.text);
    if (g.isNotEmpty && !gstValid(g)) {
      return 'GST number should be 15 characters — correct it, or clear it and use PAN / Aadhaar.';
    }
    switch (_idUsed) {
      case 'gst':
        if (_gstChecking) return 'Please wait — checking your GST number…';
        if (!_gstOk) return 'This GST number could not be verified — correct it, or clear it and use PAN / Aadhaar.';
        return null;
      case 'pan':
        if (!panValid(_pan.text)) return 'Could not read the PAN number from the photo — please take a clear, straight photo of the PAN card.';
        return null;
      case 'aadhaar':
        if (!aadhaarValid(_aadhaar.text)) return 'Could not read the Aadhaar number from the photo — please take a clear photo of the side with your address.';
        return null;
    }
    return 'Please type your GST number, or add a photo of your PAN card or Aadhaar card.';
  }

  Widget _cardBox() {
    final ph = _cardPhoto;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const Text('Old saree shop: add a photo of your visiting card or your shop board *',
            style: TextStyle(fontWeight: FontWeight.w700)),
        if (ph != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Container(color: kLinen, height: 150, child: Image.memory(ph.jpg, fit: BoxFit.contain)),
            ),
          ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(50)),
          onPressed: _reading ? null : () => _pickPhoto(false, card: true),
          icon: Icon(ph == null ? Icons.add_a_photo_rounded : Icons.cameraswitch_rounded),
          label: Text(ph == null ? 'Add photo of your shop / visiting card *' : 'Change photo',
              textAlign: TextAlign.center),
        ),
      ]),
    );
  }

  Future<void> _submit() async {
    FocusScope.of(context).unfocus();
    final okFields = _formKey.currentState?.validate() ?? false;
    final idErr = _idError();
    final bizErr = (_india && _hasGst)
        ? null
        : _businessType == null
        ? 'Please choose your business type.'
        : (_needCard && _cardPhoto == null ? 'Please add a photo of your shop / visiting card.' : null);
    setState(() {
      _photoErr = idErr;
      _bizErr = bizErr;
      _error = null;
    });
    if (!okFields || idErr != null || bizErr != null) {
      setState(() => _error = idErr ?? bizErr ?? 'Please fill the boxes marked in red.');
      return;
    }
    if (_india && _pinNotFound) {
      setState(() => _error = 'This pincode does not exist — please correct it.');
      return;
    }
    String kycDoc = '', taxId = '';
    _KycPhoto? photo;
    if (_india) {
      final used = _idUsed;
      if (used == 'gst') {
        kycDoc = 'gst';
        taxId = _norm(_gst.text);
      } else if (used == 'pan') {
        kycDoc = 'pan';
        taxId = _norm(_pan.text);
        photo = _panPhoto;
      } else {
        kycDoc = 'aadhaar';
        taxId = _aadhaar.text.replaceAll(RegExp(r'\D'), '');
        photo = _aadhaarPhoto;
      }
    }
    final cust = <String, dynamic>{
      'contact': _contact.text.trim(),
      'billName': _bill.text.trim().toUpperCase(),
      'businessType': (_india && _hasGst) ? 'gst_business' : _businessType,
      'address': _address.text.trim(),
      'pincode': _india ? _pin.text.trim() : '',
      'bookingPlace': _place.text.trim().toUpperCase(),
      'transport': _india ? _transport.text.trim().toUpperCase() : '',
      'taxId': taxId,
      'country': _india ? 'India' : _country,
      if (kycDoc.isNotEmpty) 'kycDoc': kycDoc,
    };
    setState(() => _sending = true);
    try {
      final abroadMobile = widget.abroad ? (OrderService.normalizeForeignMobile(_mobileAbroad.text) ?? '') : '';
      if (widget.abroad) cust['mobile'] = abroadMobile;
      final d = await (widget.abroad ? AccountService.signupAbroad(abroadMobile, cust) : AccountService.signup(widget.code, {
        ...cust,
        if (photo != null) 'kycImage': base64Encode(photo.jpg),
        if (photo != null) 'kycText': photo.text,
        if (_needCard && _cardPhoto != null) 'cardImage': base64Encode(_cardPhoto!.jpg),
        if (_needCard && _cardPhoto != null) 'cardText': _cardPhoto!.text,
      }));
      if (!mounted) return;
      if (d == null) {
        setState(() => _error = 'No internet — please check your connection and try again.');
        return;
      }
      if (d['ok'] != true) {
        setState(() => _error = '${d['error'] ?? 'Could not send your details. Please try again.'}');
        return;
      }
      await widget.onResult('${d['status'] ?? 'pending'}', cust);
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not send your details. Please try again.');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  // ───────────────────────── UI ─────────────────────────

  InputDecoration _dec(String label, {String? hint, String? helper, Color? helperColor, Widget? suffix}) =>
      InputDecoration(
        labelText: label,
        hintText: hint,
        helperText: helper,
        helperMaxLines: 3,
        errorMaxLines: 3,
        helperStyle: helperColor == null
            ? null
            : TextStyle(color: helperColor, fontWeight: FontWeight.w700),
        suffixIcon: suffix,
      );

  String? _need(String? v, int n, String msg) => (v ?? '').trim().length < n ? msg : null;

  @override
  Widget build(BuildContext context) {
    String? pinHelper;
    Color? pinColor;
    if (_pinChecking) {
      pinHelper = 'Checking pincode…';
    } else if (_pinNotFound) {
      pinHelper = '✗ This pincode does not exist';
      pinColor = _red;
    } else if (_pinInfo != null) {
      pinHelper = '📍 ${_pinInfo!.label}';
      pinColor = _green;
    }
    String? placeHelper;
    Color? placeColor;
    final info = _pinInfo;
    if (info != null && _place.text.trim().isNotEmpty) {
      if (OrderService.placeMatches(_place.text, info)) {
        placeHelper = '✓ Matches pincode (${info.label})';
        placeColor = _green;
      } else {
        placeHelper = '⚠ Pincode is ${info.label} — please check';
        placeColor = Colors.orange.shade800;
      }
    }
    final tGst = _transport.text.trim().isEmpty ? null : _tInfo?.gstOf(_transport.text);

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(icon: const Icon(Icons.arrow_back_rounded), onPressed: _sending ? null : widget.onBack),
        title: const UText('Sign up'),
      ),
      body: SafeArea(
        child: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(18, 14, 18, 30),
            children: [
              widget.header,
              if (widget.mobileLabel.isNotEmpty)
                Text('✓ Verified: ${widget.mobileLabel}',
                    style: const TextStyle(color: _green, fontWeight: FontWeight.w800)),
              const SizedBox(height: 6),
              const Text('New customer — please fill your details. AKN Zone will approve your account.',
                  style: TextStyle(fontSize: 14, height: 1.4)),
              const SizedBox(height: 16),
              TextFormField(
                controller: _bill,
                textCapitalization: TextCapitalization.characters,
                decoration: _dec('Bill name *', hint: 'Firm / party name'),
                validator: (v) => _need(v, 2, 'Enter bill name'),
              ),
              const SizedBox(height: 14),
              if (_india) ...[
                // Owner 14-Oct: three boxes — GST, PAN, Aadhaar. One is enough.
                const Text('Your ID — fill any one *',
                    style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15, color: _dark)),
                const SizedBox(height: 4),
                const Text('GST number fills your details by itself. No GST? Add a PAN or Aadhaar card photo.',
                    style: TextStyle(fontSize: 12.5, color: Colors.black54)),
                const SizedBox(height: 10),
                TextField(
                  controller: _gst,
                  textCapitalization: TextCapitalization.characters,
                  inputFormatters: [LengthLimitingTextInputFormatter(20)],
                  decoration: _dec('GST number', hint: '15 characters, e.g. 24ABCDE1234F1Z5'),
                ),
                if (_gstNote == null && idHint('gst', _gst.text) != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 6, left: 4),
                    child: Text(idHint('gst', _gst.text)!,
                        style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12.5, color: _red)),
                  ),
                if (_gstNote != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 6, left: 4),
                    child: Text(_gstNote!,
                        style: TextStyle(
                            fontWeight: FontWeight.w700,
                            color: _gstChecking ? Colors.black54 : (_gstOk ? _green : _red))),
                  ),
                const SizedBox(height: 12),
                if (!_hasGst) ...[
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 8),
                    child: Text('No GST? Add a photo of ONE card:',
                        style: TextStyle(fontWeight: FontWeight.w700)),
                  ),
                  _idPhoto(aadhaar: false),
                  const SizedBox(height: 10),
                  _idPhoto(aadhaar: true),
                  const Padding(
                    padding: EdgeInsets.only(top: 6),
                    child: Text('Card photos are used only to verify you and are deleted after approval.',
                        style: TextStyle(fontSize: 12.5, color: Colors.black54)),
                  ),
                ],
                if (_photoErr != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(_photoErr!, style: const TextStyle(color: _red, fontWeight: FontWeight.w700)),
                  ),
                const SizedBox(height: 16),
              ],
              const SizedBox(height: 8),
              TextFormField(
                controller: _address,
                minLines: 2,
                maxLines: 4,
                textCapitalization: TextCapitalization.words,
                decoration: _dec('Address *'),
                validator: (v) => _need(v, 5, 'Enter full address'),
              ),
              const SizedBox(height: 12),
              if (_india) ...[
                TextFormField(
                  controller: _pin,
                  keyboardType: TextInputType.number,
                  inputFormatters: [
                    FilteringTextInputFormatter.digitsOnly,
                    LengthLimitingTextInputFormatter(6),
                  ],
                  decoration: _dec('Pincode *', helper: pinHelper, helperColor: pinColor),
                  validator: (v) => OrderService.validatePincode(v ?? '', india: true),
                ),
                const SizedBox(height: 12),
              ],
              TextFormField(
                controller: _place,
                textCapitalization: TextCapitalization.characters,
                decoration: _dec(_india ? 'City / Booking place *' : 'Destination city *',
                    hint: _india ? 'City where goods are booked' : 'Your city',
                    helper: placeHelper,
                    helperColor: placeColor),
                validator: (v) => _need(v, 2, _india ? 'Enter booking place' : 'Enter your city'),
              ),
              const SizedBox(height: 12),
              if (widget.abroad) ...[
                TextFormField(
                  controller: _mobileAbroad,
                  keyboardType: TextInputType.phone,
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[0-9+ \-]')),
                    LengthLimitingTextInputFormatter(20),
                  ],
                  decoration: _dec('Mobile / WhatsApp number with country code *', hint: 'e.g. 971 50 123 4567'),
                  validator: (v) {
                    final m = OrderService.normalizeForeignMobile(v ?? '');
                    if (m == null) return 'Enter your full number with country code';
                    if (m.startsWith('91') && m.length == 12) return 'Indian numbers log in with WhatsApp';
                    return null;
                  },
                ),
                const SizedBox(height: 12),
              ],
              if (!_india)
                DropdownButtonFormField<String>(
                  key: ValueKey('signup-country-$_country'),
                  initialValue: OrderService.countries.contains(_country) ? _country : 'Other',
                  isExpanded: true,
                  decoration: _dec('Country *'),
                  items: [
                    for (final c in OrderService.countries)
                      if (c != 'India') DropdownMenuItem(value: c, child: Text(c)),
                  ],
                  onChanged: (v) => setState(() => _country = v ?? 'Other'),
                ),
              if (_india) ...[
                _TransportBox(
                  controller: _transport,
                  focusNode: _transportFocus,
                  options: _transports,
                  info: _tInfo,
                  place: _place.text,
                  decoration: _dec('Transport name *',
                      hint: 'Search or type your own',
                      suffix: const Icon(Icons.local_shipping_outlined)),
                  validator: (v) => _need(v, 2, 'Enter transport name'),
                ),
                if (tGst != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 6, left: 4),
                    child: Text('✓ GST no. of this transport: $tGst',
                        style: const TextStyle(fontWeight: FontWeight.w800, color: Color(0xFF1B5E20))),
                  ),
                _usualTransports(),
              ],
              // Owner 14-Oct: with a GST number there is no old / new question.
              if (!_india || !_hasGst) ...[
              const SizedBox(height: 18),
              // Owner 14-Oct 09:15: business type is the LAST question.
              const Text('Business type *',
                  style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15, color: _dark)),
              const SizedBox(height: 6),
              for (final o in const [
                ('new_startup', 'New startup (new to saree business)', Icons.rocket_launch_rounded),
                ('existing_business', 'Old saree shop', Icons.storefront_rounded),
              ])
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: () => setState(() {
                      _businessType = o.$1;
                      _bizErr = null;
                    }),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                      decoration: BoxDecoration(
                        color: _businessType == o.$1 ? const Color(0xFFE8F5E9) : null,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                            color: _businessType == o.$1 ? _green : kHairline,
                            width: _businessType == o.$1 ? 2 : 1),
                      ),
                      child: Row(children: [
                        Icon(
                            _businessType == o.$1
                                ? Icons.radio_button_checked_rounded
                                : Icons.radio_button_unchecked_rounded,
                            color: _businessType == o.$1 ? _green : Colors.black45),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(o.$2,
                              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
                        ),
                        const SizedBox(width: 6),
                        Icon(o.$3, color: Colors.black45, size: 20),
                      ]),
                    ),
                  ),
                ),
              if (_needCard) _cardBox(),
              if (_bizErr != null)
                Padding(
                  padding: const EdgeInsets.only(left: 4, bottom: 6),
                  child: Text(_bizErr!, style: const TextStyle(color: _red, fontWeight: FontWeight.w700)),
                ),
              ],
              const SizedBox(height: 14),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(_error!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: _red, fontWeight: FontWeight.w700)),
                ),
              _BigButton(
                label: 'Submit',
                icon: Icons.check_circle_outline_rounded,
                color: _green,
                busy: _sending,
                onPressed: _submit,
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Transports the shop's parties use for the typed city — tap to choose.
  Widget _usualTransports() {
    // Owner 14-Oct: same as the order form — suggestions stay even when a
    // transport is typed, plus where our parties use the typed one.
    final usual = _tInfo?.forPlace(_place.text) ?? const <(String, int)>[];
    final typed = _transport.text.trim();
    final goes = typed.isEmpty ? const <(String, int)>[] : (_tInfo?.placesOf(typed) ?? const <(String, int)>[]);
    if (usual.isEmpty && goes.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (goes.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text('Our parties use it for: ${goes.take(8).map((e) => e.$1).join(', ')}',
                style: const TextStyle(fontSize: 12, color: Colors.black54)),
          ),
        if (usual.isNotEmpty)
        Text('Suggestion of transports going to ${_place.text.trim().toUpperCase()} — tap to choose:',
            style: const TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 4),
        Wrap(spacing: 6, runSpacing: 4, children: [
          for (final e in usual.take(8))
            ActionChip(
              visualDensity: VisualDensity.compact,
              label: Text(e.$1, style: const TextStyle(fontSize: 12)),
              onPressed: () {
                _transport.text = e.$1;
                _transportFocus.unfocus();
              },
            ),
        ]),
      ]),
    );
  }
}

/// Searchable transport picker that also accepts a typed name, GST no.
/// beside each name (same as the order form's).
class _TransportBox extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final List<String> options;
  final InputDecoration decoration;
  final FormFieldValidator<String>? validator;
  final TransportInfo? info;
  final String place;
  const _TransportBox({
    required this.controller,
    required this.focusNode,
    required this.options,
    required this.decoration,
    this.validator,
    this.info,
    this.place = '',
  });

  @override
  Widget build(BuildContext context) {
    return RawAutocomplete<String>(
      textEditingController: controller,
      focusNode: focusNode,
      optionsBuilder: (v) {
        final q = v.text.trim().toUpperCase();
        if (q.isEmpty) {
          final usual = [for (final e in info?.forPlace(place) ?? const <(String, int)>[]) e.$1];
          return [...usual, ...options.where((o) => !usual.contains(o))].take(40);
        }
        final words = q.split(RegExp(r'\s+'));
        final starts = <String>[], has = <String>[];
        for (final o in options) {
          if (!words.every(o.contains)) continue;
          (o.startsWith(q) ? starts : has).add(o);
        }
        return [...starts, ...has].take(40);
      },
      fieldViewBuilder: (context, ctrl, focus, onSubmit) => TextFormField(
        controller: ctrl,
        focusNode: focus,
        textCapitalization: TextCapitalization.characters,
        decoration: decoration,
        validator: validator,
        onFieldSubmitted: (_) => onSubmit(),
      ),
      optionsViewBuilder: (context, onSelected, opts) {
        final list = opts.toList();
        return Align(
          alignment: Alignment.topLeft,
          child: Material(
            elevation: 6,
            borderRadius: BorderRadius.circular(8),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                  maxHeight: 260, maxWidth: MediaQuery.of(context).size.width - 36),
              child: ListView.builder(
                padding: EdgeInsets.zero,
                shrinkWrap: true,
                itemCount: list.length,
                itemBuilder: (_, i) {
                  final g = info?.gstOf(list[i]);
                  return ListTile(
                    dense: true,
                    title: Text(list[i]),
                    subtitle: g != null
                        ? Text('GST $g',
                            style: const TextStyle(fontWeight: FontWeight.w700, color: Color(0xFF1B5E20)))
                        : null,
                    onTap: () => onSelected(list[i]),
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }
}
