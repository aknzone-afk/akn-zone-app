import 'dart:async';
import '../l10n.dart';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:catalog_app/widgets/caps_text.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../models/order.dart';
import '../models/photo.dart';
import '../providers/providers.dart';
import '../services/account_service.dart';
import '../services/order_service.dart';
import '../services/drive_urls.dart';
import '../services/old_designs.dart';
import '../services/transport_info.dart';
import '../services/phone_lock.dart';
import '../services/photo_freshness.dart';
import '../services/marks_service.dart';
import '../services/picks_service.dart';
import '../services/pieces_service.dart';
import '../config.dart' show kMinOrderValue;
import '../services/stats_service.dart';
import '../widgets/hot_picks.dart';
import '../widgets/min_order_bar.dart';
import '../widgets/pick_preview.dart';
import 'pick_screen.dart' show pickNavIds;

/// ORDER NOW: the cart's designs with a quantity each, then the customer's
/// billing details, then one tap to send everything to the shop.
class OrderScreen extends ConsumerStatefulWidget {
  const OrderScreen({super.key});

  @override
  ConsumerState<OrderScreen> createState() => _OrderScreenState();
}

class _OrderScreenState extends ConsumerState<OrderScreen> {
  final _formKey = GlobalKey<FormState>();
  final Map<String, int> _qty = {};
  final Set<String> _excluded = {};

  final _billName = TextEditingController();
  final _address = TextEditingController();
  final _bookingPlace = TextEditingController();
  final _pincode = TextEditingController();
  final _mobile = TextEditingController();
  final _transport = TextEditingController();
  final _taxId = TextEditingController();
  final _note = TextEditingController();

  /// Owner 21-Nov: designs that are not in the app (design over / old
  /// designs) — the customer types number, pieces and colour choice by hand.
  final List<_OldRow> _oldRows = [_OldRow()];
  static const _kMaxOldRows = 12;

  /// The rows that carry a design number.
  List<OldDesign> _oldDesigns() => [
        for (final r in _oldRows)
          if (r.design.text.trim().isNotEmpty)
            OldDesign(
                design: r.design.text.trim().toUpperCase(),
                qty: r.qty.text.trim(),
                colours: r.colours.text.trim()),
      ];
  final _transportFocus = FocusNode();
  String _country = 'India';
  bool _usingSaved = false;

  // OLD / NEW customer (owner, 11-Oct-2026).
  bool _old = true;
  final _oldMobile = TextEditingController();
  bool _looking = false;
  String? _lookErr;

  /// Numbers this phone is already linked to — shown to pick from (owner).
  List<String> _linked = const [];

  /// Owner 12-Oct: no OLD / NEW choice. The customer types the mobile; we
  /// search by ourselves: found → their account, not found → the full form.
  String? _searched;
  bool _newForm = false;
  bool _newFormForeign = false;

  /// Existing accounts matching the GST / PAN typed in the new form.
  List<Map<String, dynamic>> _taxMatches = [];
  String? _taxSearched;
  List<Map<String, dynamic>> _matches = [];
  Map<String, dynamic>? _party;

  // Pincode check state.
  PincodeInfo? _pinInfo;
  bool _pinChecking = false;
  bool _pinNotFound = false;
  Timer? _pinDebounce;

  List<String> _transports = const [];
  TransportInfo? _tInfo;
  bool _sending = false;
  String? _lockNote;

  bool get _india => _country == 'India';

  /// Owner 14-Oct: the WhatsApp-verified account number — no FIND box.
  String? _accMobile;

  @override
  void initState() {
    super.initState();
    Stats.step('order_open'); // owner 27-Oct (3): funnel
    final saved =
        OrderService.savedCustomer(ref.read(sharedPreferencesProvider));
    if (saved != null) {
      _fill(saved);
      _usingSaved = true;
      _old = saved.kind == 'old';
      _oldMobile.text = saved.mobile;
      if (!_old) {
        _newForm = true;
        _newFormForeign = !saved.isIndia;
      }
    }
    final acc = AccountService.saved(ref.read(sharedPreferencesProvider));
    final accMobile = OrderService.normalizeIndianMobile('${acc?['mobile'] ?? ''}');
    if (acc != null && acc['india'] != false && accMobile != null) {
      _accMobile = accMobile;
      _oldMobile.text = accMobile;
      if (saved == null) WidgetsBinding.instance.addPostFrameCallback((_) => _onMobileTyped());
    }
    _oldMobile.addListener(_onMobileTyped);
    _taxId.addListener(_onTaxTyped);
    // LIVE TEST: typing "TEST …" as bill name lifts the minimum at once.
    _billName.addListener(_onBillNameTyped);
    // Tester 13-Oct: a customer saved as NEW is looked up again too — once
    // the shop has made their ledger they are an old customer (no advance).
    if (saved != null && saved.isIndia) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _onMobileTyped());
    }
    OrderService.transports().then((t) {
      if (mounted) setState(() => _transports = t);
    });
    TransportInfo.load(ref.read(sharedPreferencesProvider), ref.read(dioProvider)).then((i) {
      if (mounted) setState(() => _tInfo = i);
    });
    _transport.addListener(() => setState(() {}));
    _pincode.addListener(_onPinChanged);
    _bookingPlace.addListener(() => setState(() {}));
    _taxId.addListener(() => setState(() {}));
    if (_pincode.text.isNotEmpty) _onPinChanged();
  }

  void _fill(CustomerDetails c) {
    _country = OrderService.countries.contains(c.country) ? c.country : 'Other';
    _billName.text = c.billName;
    _address.text = c.address;
    _bookingPlace.text = c.bookingPlace;
    _pincode.text = c.pincode;
    _mobile.text = c.mobile;
    _transport.text = c.transport;
    _taxId.text = c.taxId;
  }

  /// Typing the mobile: as soon as it is a full number (+91 / 0 / spaces
  /// ignored) we look it up — no FIND tap needed.
  bool _wasLiveTest = false;
  void _onBillNameTyped() {
    final now = OrderService.liveTest(ref.read(sharedPreferencesProvider), _billName.text);
    if (now != _wasLiveTest && mounted) setState(() => _wasLiveTest = now);
  }

  void _onMobileTyped() {
    final m = OrderService.normalizeIndianMobile(_oldMobile.text);
    if (m != null && m != _searched) {
      _searched = m;
      _findParty();
    } else if (m == null && _searched != null && !_newFormForeign) {
      setState(() {
        _searched = null;
        _matches = [];
        _party = null;
        _newForm = false;
        _lookErr = null;
        _linked = const [];
      });
    }
  }

  String? _gstNote;
  bool _gstOk = false;
  String? _gstLooked;

  /// Owner 12-Oct: a full GST number is checked on the GST portal; a valid
  /// one fills bill name, address, pincode and booking place.
  Future<void> _gstLookup(String g) async {
    if (g == _gstLooked) return;
    _gstLooked = g;
    setState(() {
      _gstNote = 'Checking GST number…';
      _gstOk = true;
    });
    // Owner 17-Nov: never block on a busy server — 3 tries; then a GST with
    // a correct check digit is accepted as typed (same rule as sign-up).
    Map<String, dynamic>? r;
    for (var i = 0; i < 3; i++) {
      r = await OrderService.gstLookup(ref.read(dioProvider), g);
      if (!mounted || _gstLooked != g) return;
      if (r != null) break;
      await Future<void>.delayed(Duration(seconds: 2 + i * 2));
      if (!mounted || _gstLooked != g) return;
    }
    if (r == null || r['found'] != true) {
      final why = r == null ? 'unreachable' : '${r['reason'] ?? ''}';
      if (why != 'format' && why != 'notfound' && why != 'limit') {
        setState(() {
          _gstOk = true;
          _gstNote = '✓ GST number accepted.';
        });
        return;
      }
      setState(() {
        // Owner 12-Oct: GST not verified → remove it; goods can be taken
        // without GST.
        _gstOk = false;
        _gstNote = why == 'limit'
            ? '✗ Only 1 GST number can be checked per mobile. Please call the shop, '
                'or remove it — you can order without GST.'
            : '✗ This GST number could not be verified. Please correct it, '
                'or remove it — you can order without GST.';
      });
      _gstLooked = null; // typing it again (or correcting it) checks again
      return;
    }
    final res = r; // non-null here
    final status = '${res['status'] ?? ''}';
    final name = '${res['tradeName'] ?? ''}'.isNotEmpty ? '${res['tradeName']}' : '${res['legalName'] ?? ''}';
    setState(() {
      if (name.isNotEmpty) _billName.text = name;
      if ('${res['address'] ?? ''}'.isNotEmpty) _address.text = '${res['address']}';
      if ('${res['pin'] ?? ''}'.isNotEmpty) _pincode.text = '${res['pin']}';
      if ('${res['city'] ?? ''}'.isNotEmpty && _bookingPlace.text.trim().isEmpty) {
        _bookingPlace.text = '${res['city']}';
      }
      _gstOk = status.toLowerCase() == 'active' || status.isEmpty;
      _gstNote = _gstOk
          ? '✓ GST verified — ${res['legalName']}. Details filled; change anything if needed.'
          : '✗ This GST number is $status on the GST portal. Please correct it, '
              'or remove it — you can order without GST.';
    });
  }

  /// GST / PAN typed in the new form that already belongs to a party.
  Future<void> _onTaxTyped() async {
    final tax = _taxId.text.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
    if (RegExp(r'^\d{2}[A-Z]{5}\d{4}[A-Z][0-9A-Z]Z[0-9A-Z]$').hasMatch(tax)) {
      // ignore: unawaited_futures
      _gstLookup(tax);
    } else if (_gstNote != null) {
      setState(() {
        _gstNote = null;
        _gstLooked = null;
      });
    }
    final ok = RegExp(r'^\d{2}[A-Z]{5}\d{4}[A-Z][0-9A-Z]Z[0-9A-Z]$').hasMatch(tax) ||
        RegExp(r'^[A-Z]{5}\d{4}[A-Z]$').hasMatch(tax);
    if (!ok) {
      if (_taxMatches.isNotEmpty) setState(() => _taxMatches = []);
      _taxSearched = null;
      return;
    }
    if (tax == _taxSearched) return;
    _taxSearched = tax;
    try {
      final list = await OrderService.lookupPartyByTax(ref.read(dioProvider), tax);
      if (mounted) setState(() => _taxMatches = list);
    } catch (_) {}
  }

  void _useAccount(Map<String, dynamic> pt) {
    setState(() {
      _matches = [pt];
      _party = pt;
      _newForm = false;
      _newFormForeign = false;
      _taxMatches = [];
      _lookErr = null;
    });
  }

  Future<void> _findParty() async {
    FocusScope.of(context).unfocus();
    final m = OrderService.normalizeIndianMobile(_oldMobile.text);
    if (m == null) {
      setState(() => _lookErr = 'Enter your 10-digit mobile number');
      return;
    }
    setState(() {
      _looking = true;
      _lookErr = null;
      _matches = [];
      _party = null;
      _linked = const [];
    });
    // Only LOOKING a number up — don't link it to this phone yet.
    final lock = await PhoneLock.check(ref.read(dioProvider), m, peek: true);
    if (!lock.allowed && _accMobile == null) {
      if (mounted) {
        setState(() {
          _looking = false;
          _lookErr = 'This phone is already linked to these numbers — tap one to order with it:';
          _linked = lock.mobiles;
        });
      }
      return;
    }
    try {
      final list = await OrderService.lookupParty(ref.read(dioProvider), m);
      if (!mounted) return;
      setState(() {
        _matches = list;
        if (list.length == 1) _party = list.first;
        _loadTransportOverride();
        _newForm = list.isEmpty; // not with us → the new-customer form
        if (list.isEmpty) _mobile.text = m;
      });
    } catch (_) {
      if (mounted) setState(() => _lookErr = 'No internet — will try again by itself…');
      // Tester 12-Oct: retry on its own when the connection is back.
      Future<void>.delayed(const Duration(seconds: 5), () {
        if (mounted && _lookErr != null && _searched == m &&
            OrderService.normalizeIndianMobile(_oldMobile.text) == m) {
          _findParty();
        }
      });
    } finally {
      if (mounted) setState(() => _looking = false);
    }
  }

  Widget _partyCard(Map<String, dynamic> pt, {bool selectable = false}) {
    String v(String k) => '${pt[k] ?? ''}'.trim();
    final lines = <String>[
      if (v('address').isNotEmpty) v('address'),
      [v('dest'), v('pincode')].where((s) => s.isNotEmpty).join(' - '),
      if ((_party == pt && _tOverride != null) || v('transport').isNotEmpty)
        'Transport: ${_party == pt && _tOverride != null ? _tOverride : v('transport')}',
      if (v('gstin').isNotEmpty) 'GST/PAN: ${v('gstin')}',
    ].where((s) => s.isNotEmpty).toList();
    final chosen = _party == pt;
    return Card(
      margin: const EdgeInsets.only(top: 10),
      color: chosen ? const Color(0xFFE8F5E9) : null,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(
            color: chosen ? const Color(0xFF2E7D32) : const Color(0xFFE8E3DA)),
      ),
      child: ListTile(
        onTap: selectable ? () => setState(() { _party = pt; _loadTransportOverride(); }) : null,
        leading: Icon(chosen ? Icons.check_circle_rounded : Icons.storefront_rounded,
            color: chosen ? const Color(0xFF2E7D32) : null),
        title: Text(v('name'), style: const TextStyle(fontWeight: FontWeight.w800)),
        subtitle: Text(lines.join('\n')),
        isThreeLine: lines.length > 1,
      ),
    );
  }

  void _clearSaved() {
    setState(() {
      _fill(CustomerDetails());
      _usingSaved = false;
      _pinInfo = null;
      _pinNotFound = false;
    });
  }

  @override
  void dispose() {
    _pinDebounce?.cancel();
    _oldMobile.removeListener(_onMobileTyped);
    _taxId.removeListener(_onTaxTyped);
    _billName.removeListener(_onBillNameTyped);
    for (final c in [
      _oldMobile,
      _billName,
      _address,
      _bookingPlace,
      _pincode,
      _mobile,
      _transport,
      _taxId,
      _note
    ]) {
      c.dispose();
    }
    for (final r in _oldRows) {
      r.dispose();
    }
    _oldFind.dispose();
    _oldTimer?.cancel();
    _transportFocus.dispose();
    super.dispose();
  }

  void _onPinChanged() {
    _pinDebounce?.cancel();
    final pin = _pincode.text.trim();
    if (!_india || !RegExp(r'^[1-9]\d{5}$').hasMatch(pin)) {
      if (_pinInfo != null || _pinNotFound) {
        setState(() {
          _pinInfo = null;
          _pinNotFound = false;
        });
      }
      return;
    }
    _pinDebounce = Timer(const Duration(milliseconds: 350), () async {
      setState(() => _pinChecking = true);
      try {
        final info =
            await OrderService.lookupPincode(ref.read(dioProvider), pin);
        if (!mounted || _pincode.text.trim() != pin) return;
        setState(() {
          _pinInfo = info;
          _pinNotFound = info == null;
          // Empty Booking Place → fill it from the pincode.
          if (info != null && _bookingPlace.text.trim().isEmpty) {
            _bookingPlace.text = info.district;
          }
        });
      } catch (_) {
        // Offline / service down: skip the check, never block the order.
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

  /// Pieces for a design, in priority order: what the customer set with
  /// + / −, else what their marks on the photo say (ticked / numbered /
  /// crossed sarees), else every saree in the photo, else 1.
  int _qtyFor(Photo p) {
    if (_qty.containsKey(p.id)) return _qty[p.id]!;
    final count = ref.read(piecesProvider.notifier).piecesFor(p);
    final pk = ref.read(picksProvider)[p.id];
    // Tap-select wins over marks / photo count; sets are never dropped.
    if (pk != null && !pk.isEmpty) return pk.minTotal(count);
    return ref.read(marksProvider)[p.id] ?? count ?? 1;
  }

  bool _qtySure(Photo p) {
    if (_qty.containsKey(p.id)) return true;
    final count = ref.read(piecesProvider.notifier).piecesFor(p);
    final pk = ref.read(picksProvider)[p.id];
    if (pk != null && !pk.isEmpty) return pk.exact(count);
    return ref.read(marksProvider).containsKey(p.id) || count != null;
  }

  String _marksSig = '';
  void _readMarks(List<Photo> photos, Map<String, int> edits) {
    final sig = '${photos.map((p) => p.id).join(',')}|${edits.keys.join(',')}';
    if (sig == _marksSig) return;
    _marksSig = sig;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(marksProvider.notifier).ensure(photos, edits.keys.toSet());
    });
  }

  ({
    int known,
    int unpriced,
    bool below,
    double progress
  }) _check(List<Photo> photos) {
    final v = OrderService.valueCheck(photos
        .map((p) => (price: p.price, qty: _qtyFor(p), sure: _qtySure(p))));
    // Add-on window open (for THIS number) → no minimum. Owner's LIVE TEST
    // (bill name "TEST …") → no minimum either.
    if (OrderService.activeParcel(ref.read(sharedPreferencesProvider), mobile: _mobileNow) != null ||
        (_newForm && OrderService.liveTest(ref.read(sharedPreferencesProvider), _billName.text))) {
      return (known: v.known, unpriced: v.unpriced, below: false, progress: 1.0);
    }
    return v;
  }

  List<Photo> _orderPhotos() {
    final favs = ref.watch(favoritesProvider);
    final all = ref.watch(photosProvider);
    return all
        .where((p) => favs.contains(p.id) && !_excluded.contains(p.id))
        .toList();
  }

  /// The number this order is for (window / minimum / advance are per number).
  String get _mobileNow => _newForm ? _mobile.text : _oldMobile.text;

  bool _submitting = false; // _submit running (the checks before the dialog)

  Future<void> _submit(List<Photo> photos) async {
    // Tester 13-Oct: a 2nd tap while the phone-lock / new-party checks ran
    // (no dialog yet, button still live) placed a 2nd order.
    if (_sending || _submitting || photos.isEmpty) return;
    setState(() => _submitting = true);
    try {
      await _submitChecked(photos);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _submitChecked(List<Photo> photos) async {
    FocusScope.of(context).unfocus();
    final marks = ref.read(marksProvider.notifier);
    if (photos.any((p) => marks.isReading(p.id))) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(t('Reading your marks on the photos — one moment…', 'फ़ोटो पढ़ रहे हैं — एक पल…'))));
      return;
    }
    // Owner 21-Nov: an old design needs its number AND how many pieces.
    for (final r in _oldRows) {
      final d = r.design.text.trim(), q = r.qty.text.trim();
      final other = q.isNotEmpty || r.colours.text.trim().isNotEmpty;
      if (d.isEmpty && other) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(t('"Design not in app": type the design number too.',
                '"जो डिज़ाइन ऐप में नहीं": डिज़ाइन नंबर भी लिखें।'))));
        return;
      }
      if (d.isNotEmpty && q.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(t('How much of design ${d.toUpperCase()}? Write the quantity — 1 set, 10 pcs…',
                'डिज़ाइन ${d.toUpperCase()} कितना चाहिए? लिखें — 1 सेट, 10 पीस…'))));
        return;
      }
    }
    if (_check(photos).below) {
      Stats.step('order_blocked'); // owner 27-Oct (3)
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(t('Minimum order is ${MinOrderBar.minLabel}. Please select a few more designs.',
              'कम से कम ${MinOrderBar.minLabel} का ऑर्डर होना चाहिए। कुछ और डिज़ाइन चुनें।'))));
      return;
    }
    if (!_newForm) {
      if (_party == null) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(_accMobile != null
                ? 'Finding your account — one moment, then tap Place order again.'
                : 'Type your 10-digit mobile number first.')));
        return;
      }
      await _send(photos, _oldCustomer());
      return;
    }
    if (!(_formKey.currentState?.validate() ?? false)) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(t('Please fill the highlighted fields.', 'लाल वाले खाने भरें।'))));
      return;
    }
    if (_pinNotFound) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(t('This pincode does not exist. Please check it.', 'यह पिनकोड सही नहीं है, जाँच करें।'))));
      return;
    }
    // Booking place that doesn't belong to the pincode → gentle confirm only
    // (goods are sometimes booked to a nearby city).
    final info = _pinInfo;
    if (info != null && !OrderService.placeMatches(_bookingPlace.text, info)) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(t('Please check', 'कृपया जाँचें')),
          content: Text(
              'Pincode ${_pincode.text.trim()} is ${info.label}, but Booking '
              'Place is "${_bookingPlace.text.trim()}".\n\nIs that correct?'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(t('Let me fix', 'ठीक करता हूँ'))),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(t('Yes, correct', 'हाँ, सही है'))),
          ],
        ),
      );
      if (ok != true || !mounted) return;
    }

    final customer = CustomerDetails(
      country: _country,
      billName: _billName.text.trim(),
      address: _address.text.trim(),
      bookingPlace: _bookingPlace.text.trim(),
      pincode: _pincode.text.trim(),
      mobile: _mobile.text.trim(),
      transport: _transport.text.trim(),
      taxId: _taxId.text.trim().toUpperCase(),
    );

    await _send(photos, customer);
  }

  CustomerDetails _oldCustomer() {
    final pt = _party!;
    String v(String k) => '${pt[k] ?? ''}'.trim();
    return CustomerDetails(
      kind: 'old',
      country: v('country').isEmpty ? 'India' : v('country'),
      billName: v('name'),
      address: v('address'),
      bookingPlace: v('dest'),
      pincode: v('pincode'),
      mobile: OrderService.normalizeIndianMobile(_oldMobile.text) ?? _oldMobile.text.trim(),
      transport: _tOverride ?? v('transport'),
      taxId: v('gstin'),
    );
  }

  /// Owner 14-Oct: an old customer may change ONLY the transport.
  String? _tOverride;
  String get _tKey => 'transport_override_${'${_party?['name'] ?? ''}'.toUpperCase()}';

  void _loadTransportOverride() {
    final v = ref.read(sharedPreferencesProvider).getString(_tKey);
    _tOverride = (v == null || v.trim().isEmpty) ? null : v;
  }

  Future<void> _editTransport() async {
    final cur = _tOverride ?? '${_party?['transport'] ?? ''}'.trim();
    final ctrl = TextEditingController(text: cur);
    final picked = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setSt) {
        final q = ctrl.text.trim().toUpperCase();
        final all = _tInfo?.choices(_transports) ?? _transports;
        final opts = TransportInfo.search(all, q, max: 30);
        final canSave = TransportInfo.ok(_tInfo, _transports, ctrl.text);
        return Padding(
          padding: EdgeInsets.fromLTRB(16, 16, 16, MediaQuery.of(ctx).viewInsets.bottom + 16),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const Text('Change your transport', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
            const SizedBox(height: 10),
            TextField(
              controller: ctrl,
              autofocus: true,
              textCapitalization: TextCapitalization.characters,
              decoration: _dec('Transport name', hint: 'Type and choose from the list'),
              onChanged: (_) => setSt(() {}),
            ),
            const SizedBox(height: 6),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 260),
              child: ListView(shrinkWrap: true, children: [
                for (final o in opts) ListTile(dense: true, title: Text(o), onTap: () => Navigator.pop(ctx, o)),
                if (opts.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(12),
                    child: Text('Not found — try another spelling. You can only choose a transport from our list.'),
                  ),
              ]),
            ),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: canSave ? () => Navigator.pop(ctx, ctrl.text.trim().toUpperCase()) : null,
              child: Text(canSave ? 'SAVE TRANSPORT' : 'CHOOSE FROM THE LIST'),
            ),
          ]),
        );
      }),
    );
    if (picked == null || picked.trim().length < 2 || !mounted) return;
    final orig = '${_party?['transport'] ?? ''}'.trim();
    final prefs = ref.read(sharedPreferencesProvider);
    setState(() {
      if (picked.toUpperCase() == orig.toUpperCase()) {
        _tOverride = null;
        prefs.remove(_tKey);
      } else {
        _tOverride = picked.toUpperCase();
        prefs.setString(_tKey, _tOverride!);
      }
    });
  }

  /// Same designs + pieces sent in the last 24 hours (owner)?
  bool _isDuplicate(List<Photo> photos) {
    String sig(Iterable<(String, int)> it) {
      final l = it.map((e) => '${e.$1}x${e.$2}').toList()..sort();
      return l.join(',');
    }
    final now = sig(photos.map((p) => (p.id, _qtyFor(p))));
    final cutoff = DateTime.now().subtract(const Duration(hours: 24));
    return OrderService.history(ref.read(sharedPreferencesProvider)).any((o) =>
        o.createdAt.isAfter(cutoff) &&
        !o.awaitingAdvance && // an unpaid (held) order isn't "already sent"
        sig(o.items.map((i) => (i.photoId, i.qty))) == now);
  }

  /// True = go ahead and send. Problems → a clear message; a mobile / GST
  /// already with us → one tap to search as OLD CUSTOMER; transport / place
  /// not in our list → tap the right name (or keep what was typed).
  Future<bool> _newPartyCheck(CustomerDetails customer) async {
    final r = await OrderService.checkNewParty(ref.read(dioProvider), customer);
    if (r == null || !mounted) return true; // offline check never blocks an order
    if (r.errors.isNotEmpty) {
      final known = r.errors.any((e) => e['field'] == 'mobile' || e['field'] == 'taxId');
      final goOld = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          icon: const Icon(Icons.error_outline_rounded, color: Color(0xFFD32F2F), size: 44),
          title: const Text('Please check'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            for (final e in r.errors)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Text('${e['msg']}', style: const TextStyle(fontSize: 16, height: 1.35)),
              ),
          ]),
          actions: [
            if (known)
              FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('SEARCH AS OLD CUSTOMER'))
            else
              FilledButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('OK, I WILL FIX')),
          ],
        ),
      );
      if (goOld == true && mounted) {
        setState(() {
          _old = true;
          _oldMobile.text = customer.mobile.replaceAll(RegExp(r'\D'), '');
        });
        await _findParty();
      }
      return false;
    }
    var changed = false;
    if (r.rename != null && r.rename!.isNotEmpty) {
      // Same bill name already in Tally → "NAME (BOOKING PLACE)" (owner).
      _billName.text = r.rename!;
      customer.billName = r.rename!; // goes out with this order straight away
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Bill name saved as "${r.rename}" (this name is already with us).')));
    }
    if (r.soft.isEmpty) return true;
    for (final e in r.soft) {
      if (!mounted) return false;
      final sugg = [for (final x in (e['suggest'] as List? ?? const [])) '$x'];
      final pick = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('${e['msg']}', style: const TextStyle(fontSize: 17)),
          content: Wrap(spacing: 8, runSpacing: 8, children: [
            for (final x in sugg)
              ActionChip(label: Text(x), onPressed: () => Navigator.pop(ctx, x)),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, ''), child: const Text('KEEP WHAT I TYPED')),
          ],
        ),
      );
      if (pick == null) return false;
      if (pick.isNotEmpty) {
        (e['field'] == 'transport' ? _transport : _bookingPlace).text = pick;
        changed = true;
      }
    }
    if (changed && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Updated ✓ — please check and press ORDER again.')));
      return false;
    }
    return true;
  }

  Future<void> _send(List<Photo> photos, CustomerDetails customer) async {
    // Owner 14-Oct: one last "are you sure?" before the order goes.
    final pcs = photos.fold<int>(0, (s, p) => s + _qtyFor(p));
    final preN = photos.where((p) => DriveUrls.isOld(p.id)).length;
    final preLine = preN == 0 ? '' : t('(incl. $preN pre order — not ready, approx 2 weeks)\n', '($preN प्री ऑर्डर — लगभग 2 हफ़्ते)\n');
    final sure = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Text(t('Place this order?', 'यह ऑर्डर भेजें?')),
        content: Text(t(
            '${photos.length} design${photos.length == 1 ? '' : 's'} · $pcs pcs\n$preLine'
                'Bill name: ${customer.billName}\n\n'
                'Your order will be placed. Tap YES only if everything is right.',
            '${photos.length} डिज़ाइन · $pcs पीस\n$preLine'
                'बिल नाम: ${customer.billName}\n\n'
                'आपका ऑर्डर लग जाएगा। सब सही हो तभी YES दबाएँ।')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('NO')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('YES, PLACE ORDER')),
        ],
      ),
    );
    if (sure != true || !mounted) return;
    if (_isDuplicate(photos)) {
      final again = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Already sent'),
          content: const Text(
              'You sent this same order in the last 24 hours. Send it again?'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('No')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Send again')),
          ],
        ),
      );
      if (again != true || !mounted) return;
    }
    // Phone lock: at most 2 numbers per phone.
    final digits = customer.mobile.replaceAll(RegExp(r'\D'), '');
    final lock = await PhoneLock.check(ref.read(dioProvider), digits);
    if (!mounted) return;
    if (!lock.allowed) {
      // Owner 12-Oct: show the numbers this phone is linked to — pick one.
      final pick = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          icon: const Icon(Icons.phone_iphone_rounded, color: Color(0xFFD32F2F), size: 44),
          title: const Text('This phone is linked to these numbers'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('Tap the number you want to order with:'),
            const SizedBox(height: 10),
            for (final m in lock.mobiles)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.phone_iphone_rounded),
                    label: Text('+91 $m',
                        style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
                    onPressed: () => Navigator.pop(ctx, m),
                  ),
                ),
              ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('CANCEL')),
          ],
        ),
      );
      if (pick != null && mounted) {
        setState(() {
          _old = true;
          _oldMobile.text = pick;
        });
        await _findParty();
      }
      return;
    }
    // New customer: tell them NOW what the shop's Tally would refuse (owner).
    if (customer.kind != 'old' &&
        OrderService.activeParcel(ref.read(sharedPreferencesProvider), mobile: customer.mobile) == null) {
      if (!await _newPartyCheck(customer) || !mounted) return;
    }
    // Owner 14-Oct: no phone-lock lines any more (WhatsApp-verified accounts);
    // only a transport the customer changed is told to the staff.
    final oldT = _party == null ? '' : '${_party!['transport'] ?? ''}'.trim();
    final lockNote = [
      if (lock.index < 0) '',
      if (_party != null && _tOverride != null && _tOverride!.toUpperCase() != oldT.toUpperCase())
        '🚚 Customer changed transport: ${oldT.isEmpty ? '-' : oldT} → $_tOverride',
    ].where((x) => x.isNotEmpty).join('\n');
    _lockNote = lockNote.isEmpty ? null : lockNote;
    setState(() => _sending = true);
    final step = ValueNotifier<String>('Preparing…');
    // ignore: unawaited_futures
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => PopScope(
        canPop: false,
        child: AlertDialog(
          // Owner 25-Oct: "please don't close the app" — in big letters.
          title: Text(t('📤 Sending your order — please do NOT close the app',
              '📤 ऑर्डर भेज रहे हैं — कृपया ऐप बंद न करें'),
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: Color(0xFFB71C1C))),
          content: Row(children: [
            const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2.5)),
            const SizedBox(width: 18),
            Expanded(
              child: ValueListenableBuilder<String>(
                valueListenable: step,
                builder: (_, s, __) => Text(s),
              ),
            ),
          ]),
        ),
      ),
    );

    Order? order;
    OrderPhotosMissing? missingPhotos;
    try {
      order = await OrderService.place(
        prefs: ref.read(sharedPreferencesProvider),
        dio: ref.read(dioProvider),
        editService: ref.read(editServiceProvider),
        photos: photos,
        qty: {for (final p in photos) p.id: _qtyFor(p)},
        picks: ref.read(picksProvider),
        sareeCounts: {
          for (final p in photos)
            if (ref.read(piecesProvider.notifier).piecesFor(p) != null)
              p.id: ref.read(piecesProvider.notifier).piecesFor(p)!,
        },
        pickLabels: {
          for (final p in photos)
            if (ref.read(picksProvider)[p.id] != null)
              p.id: ref
                  .read(picksProvider)[p.id]!
                  .label(ref.read(piecesProvider.notifier).piecesFor(p)),
        },
        customer: customer,
        note: _note.text,
        oldDesigns: _oldDesigns(),
        lockNote: _lockNote,
        onStep: (s) => step.value = s,
        // Owner 14-Oct: no 10% token any more — customers are verified at
        // sign-up; the bill comes first, payment after it.
        holdForAdvance: false,
      );
    } on OrderPhotosMissing catch (e) {
      order = null;
      missingPhotos = e;
    } catch (e) {
      order = null;
    }
    if (!mounted) return;
    Navigator.of(context, rootNavigator: true).pop(); // progress dialog
    setState(() => _sending = false);

    // Tester 13-Oct: some photos could not be downloaded even after retries —
    // the order was NOT placed (nothing is dropped silently); say which.
    final miss = missingPhotos;
    if (order == null && miss != null) {
      final names = miss.designs
          .map((d) => d.isEmpty ? '?' : 'D.No $d')
          .take(12)
          .join(', ');
      final more = miss.designs.length > 12 ? ' …' : '';
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(t('Order not placed yet', 'ऑर्डर अभी नहीं हुआ')),
          content: Text(t(
              '${miss.designs.length} photo(s) could not be downloaded: '
                  '$names$more\n\nPlease check your internet and tap Place order again. Your cart is safe.',
              '${miss.designs.length} फोटो डाउनलोड नहीं हुई: $names$more\n\n'
                  'इंटरनेट जाँचें और फिर से ऑर्डर भेजें दबाएँ। आपका कार्ट सुरक्षित है।')),
          actions: [
            FilledButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('OK')),
          ],
        ),
      );
      return;
    }
    if (order == null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(t('Could not place the order. Please try again.', 'ऑर्डर नहीं हुआ, फिर से कोशिश करें।'))));
      return;
    }
    HapticFeedback.mediumImpact();
    Stats.step('order_sent'); // owner 27-Oct (3)
    // Owner: the cart empties by itself once the order is placed.
    await ref.read(favoritesProvider.notifier).clear();
    if (!mounted) return;
    if (order.awaitingAdvance) {
      context.go('/advance/${Uri.encodeComponent(order.number)}');
      return;
    }
    await _showDone(order);
    if (!mounted) return;
    context.go('/');
  }

  Future<bool?> _showDone(Order o) {
    final sent = o.status == OrderStatus.sent;
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        icon: Icon(sent ? Icons.check_circle_rounded : Icons.schedule_rounded,
            size: 48, color: sent ? const Color(0xFF2E7D32) : Colors.orange),
        title: Text(sent ? t('Order placed!', 'ऑर्डर हो गया!') : t('Order saved', 'ऑर्डर सेव हो गया')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SelectableText(
                o.addOnTo != null ? 'Added to your parcel' : (o.serial != null ? 'ORDER NO. ${o.serial}' : 'Order saved'),
                style: const TextStyle(
                    fontWeight: FontWeight.w800, letterSpacing: 1)),
            const SizedBox(height: 10),
            Text(
              sent
                  ? '${o.items.length} designs · ${o.totalPcs} pcs reached us. '
                      'We will contact you on WhatsApp shortly.'
                  : 'No connection right now. Your order is safe on this phone '
                      'and will be sent automatically when internet is back. '
                      'See "My Orders".',
              textAlign: TextAlign.center,
            ),
          ],
        ),
        actions: [
          SizedBox(
            width: double.infinity,
            height: 48,
            child: FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('OK')),
          ),
        ],
      ),
    );
  }

  // ─────────── designs that are NOT in the app (owner 21-Nov-2026) ───────────
  // Type the design number -> its photos from the shop's full photo set ->
  // tap one -> select colours / pieces like any design -> it joins this order.
  final _oldFind = TextEditingController();
  Timer? _oldTimer;
  int _oldSeq = 0; // only the newest look-up may show its result
  bool _oldBusy = false;
  List<String> _oldIds = const []; // photos of the typed design (shop's full photo set)
  List<String> _oldInAppIds = const []; // the typed design IS in the app: its photos there
  String _oldKey = '';
  String? _oldMsg;
  bool _oldManual = false; // no photo: quantity is typed by hand (the rows below)
  final _oldResultKey = GlobalKey(); // the photos (or the OPEN button) — brought into view above the keyboard

  /// Typing the number shows the photo by itself (as on the shop's Rate Bolo
  /// page); the button and the keyboard's search key do the same at once.
  void _oldTyped(String v) {
    _oldTimer?.cancel();
    if (OldDesigns.keyOf(v).length < 3) return;
    _oldTimer = Timer(const Duration(milliseconds: 900), () {
      if (mounted) _findOld(typing: true);
    });
  }

  Future<void> _findOld({bool typing = false}) async {
    _oldTimer?.cancel();
    if (!typing) FocusScope.of(context).unfocus();
    final key = OldDesigns.keyOf(_oldFind.text);
    if (key.isEmpty) return;
    final seq = ++_oldSeq;
    setState(() => _oldBusy = true);
    // A design that IS in the app is ready goods — it is selected there, not here.
    final base = OldDesigns.baseOf(key);
    final inApp = [
      for (final p in ref.read(catalogPhotosProvider))
        if (OldDesigns.catalogKey(p.designNumber ?? p.filename) == base) p.id,
    ];
    var ids = const <String>[];
    var failed = false;
    if (inApp.isEmpty) {
      try {
        ids = await OldDesigns.idsFor(ref.read(dioProvider), key);
      } catch (_) {
        failed = true;
      }
    }
    if (!mounted || seq != _oldSeq) return;
    if (ids.isNotEmpty) ref.read(oldPhotosProvider.notifier).show(ids);
    setState(() {
      _oldBusy = false;
      _oldKey = key;
      _oldInAppIds = inApp;
      _oldIds = ids;
      if (inApp.isNotEmpty) {
        _oldMsg = t('Design $key is in the app — it is ready. Tap OPEN and select it there.',
            'डिज़ाइन $key ऐप में है — तैयार है। OPEN दबाकर वहीं से चुनें।');
      } else if (ids.isNotEmpty) {
        _oldMsg = t('Tap the photo, select colours / pieces and press DONE — it is added to this order.',
            'फ़ोटो दबाएँ, रंग / पीस चुनें और DONE दबाएँ — इसी ऑर्डर में जुड़ जाएगा।');
      } else if (failed) {
        _oldMsg = t('Could not load the photo — check the internet and tap SHOW PHOTO.',
            'फ़ोटो नहीं खुली — इंटरनेट देखें और SHOW PHOTO दबाएँ।');
      } else if (typing) {
        // still typing, perhaps: say it softly, change nothing
        _oldMsg = t('No photo of design $key.', 'डिज़ाइन $key की फ़ोटो नहीं मिली।');
      } else {
        _oldMsg = t('No photo of design $key. Write how much you want below.',
            'डिज़ाइन $key की फ़ोटो नहीं मिली। नीचे लिख दें कितना चाहिए।');
        _oldManual = true;
        if (!_oldRows.any((r) => OldDesigns.keyOf(r.design.text) == key)) {
          final free = _oldRows.where((r) => r.design.text.trim().isEmpty).firstOrNull;
          if (free != null) {
            free.design.text = key;
          } else if (_oldRows.length < _kMaxOldRows) {
            _oldRows.add(_OldRow()..design.text = key);
          }
          if (_oldRows.last.design.text.trim().isNotEmpty && _oldRows.length < _kMaxOldRows) _oldRows.add(_OldRow());
        }
      }
    });
    // The photos open below the field — with the keyboard up they would sit
    // behind it. Scroll just enough to show them (never when already seen).
    if (ids.isNotEmpty || inApp.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final c = _oldResultKey.currentContext;
        if (!mounted || c == null) return;
        // ignore: discarded_futures
        Scrollable.ensureVisible(c,
            duration: const Duration(milliseconds: 250),
            alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd);
      });
    }
  }

  void _pickOld(String id) {
    ref.read(oldPhotosProvider.notifier).show(_oldIds);
    pickNavIds = _oldIds; // ◀ / ▶ in the select screen walk this design's photos
    context.push('/pick/${Uri.encodeComponent(id)}');
  }

  Widget _oldDesignBox() {
    final inCart = ref.watch(favoritesProvider);
    return Container(
      key: const ValueKey('old-designs-box'),
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF8E7),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE0C98A)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        UText(t('Design not in app?', 'डिज़ाइन ऐप में नहीं है?'),
            style: const TextStyle(fontWeight: FontWeight.w800, letterSpacing: 0.8, fontSize: 13)),
        const SizedBox(height: 2),
        Text(
            t('That design is not ready right now. If you still want to order it, type its number here — '
                    'the goods will be ready in approx 2 weeks.',
                'वह डिज़ाइन अभी तैयार नहीं है। फिर भी ऑर्डर देना चाहते हैं तो उसका नंबर यहाँ लिखें — '
                    'माल लगभग 2 हफ़्ते में निकलेगा।'),
            style: const TextStyle(fontSize: 12.5, color: Colors.black87)),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(
            child: TextField(
              key: const ValueKey('old-find'),
              controller: _oldFind,
              textCapitalization: TextCapitalization.characters,
              textInputAction: TextInputAction.search,
              inputFormatters: [LengthLimitingTextInputFormatter(24)],
              decoration: _dec(t('Design no.', 'डिज़ाइन नं.')),
              onChanged: _oldTyped,
              onSubmitted: (_) => _findOld(),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            height: 48,
            child: FilledButton(
              key: const ValueKey('old-find-btn'),
              onPressed: _oldBusy ? null : () => _findOld(),
              child: _oldBusy
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2.2, color: Colors.white))
                  : Text(t('SHOW PHOTO', 'फ़ोटो दिखाएँ'), style: const TextStyle(fontWeight: FontWeight.w800)),
            ),
          ),
        ]),
        if (_oldMsg != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(_oldMsg!,
                style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: _oldIds.isNotEmpty || _oldInAppIds.isNotEmpty ? const Color(0xFF1B5E20) : const Color(0xFF8A4B00))),
          ),
        if (_oldInAppIds.isNotEmpty)
          Align(
            key: _oldResultKey,
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: const ValueKey('old-open'),
              onPressed: () => context.push('/photo/${Uri.encodeComponent(_oldInAppIds.first)}', extra: _oldInAppIds),
              icon: const Icon(Icons.open_in_new_rounded, size: 18),
              label: Text(t('OPEN design $_oldKey', 'डिज़ाइन $_oldKey खोलें')),
            ),
          ),
        if (_oldIds.isNotEmpty)
          Padding(
            key: _oldResultKey,
            padding: const EdgeInsets.only(top: 8),
            child: SizedBox(
              height: 190,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: _oldIds.length,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (_, i) {
                  final id = _oldIds[i];
                  final added = inCart.contains(id);
                  return GestureDetector(
                    key: ValueKey('old-photo-$i'),
                    onTap: () => _pickOld(id),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: SizedBox(
                        width: 127,
                        child: Stack(fit: StackFit.expand, children: [
                          CachedNetworkImage(
                            imageUrl: DriveUrls.thumbnail(id),
                            cacheManager: photoCacheManager,
                            fit: BoxFit.cover,
                            placeholder: (_, __) => const ColoredBox(color: Color(0xFFEDE6D6)),
                            errorWidget: (_, __, ___) =>
                                const ColoredBox(color: Color(0xFFEDE6D6), child: Icon(Icons.broken_image_outlined)),
                          ),
                          Positioned(
                            left: 0,
                            right: 0,
                            bottom: 0,
                            child: Container(
                              color: added ? const Color(0xFF1B8E3A) : Colors.black87,
                              padding: const EdgeInsets.symmetric(vertical: 5),
                              alignment: Alignment.center,
                              child: Text(added ? t('✓ IN ORDER', '✓ ऑर्डर में') : t('SELECT', 'चुनें'),
                                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 12)),
                            ),
                          ),
                        ]),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        if (!_oldManual)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: () => setState(() => _oldManual = true),
              child: Text(t('No photo? Write design no. + quantity', 'फ़ोटो नहीं? डिज़ाइन नं. + कितना चाहिए लिखें'),
                  style: const TextStyle(fontSize: 12.5)),
            ),
          ),
        if (_oldManual) ...[
          const SizedBox(height: 10),
          for (var i = 0; i < _oldRows.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(
                  flex: 9,
                  child: TextField(
                    key: ValueKey('old-design-$i'),
                    controller: _oldRows[i].design,
                    textCapitalization: TextCapitalization.characters,
                    textInputAction: TextInputAction.next,
                    inputFormatters: [LengthLimitingTextInputFormatter(24)],
                    decoration: _dec(t('Design no.', 'डिज़ाइन नं.')),
                    // typed in the last row -> the next empty row opens by itself
                    onChanged: (v) {
                      if (v.trim().isNotEmpty && i == _oldRows.length - 1 && _oldRows.length < _kMaxOldRows) {
                        setState(() => _oldRows.add(_OldRow()));
                      }
                    },
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  flex: 9,
                  child: TextField(
                    key: ValueKey('old-qty-$i'),
                    controller: _oldRows[i].qty,
                    textInputAction: TextInputAction.next,
                    inputFormatters: [LengthLimitingTextInputFormatter(40)],
                    decoration: _dec(t('Quantity', 'कितना'), hint: t('1 set / 10 pcs', '1 सेट / 10 पीस')),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  flex: 9,
                  child: TextField(
                    key: ValueKey('old-colours-$i'),
                    controller: _oldRows[i].colours,
                    textCapitalization: TextCapitalization.sentences,
                    inputFormatters: [LengthLimitingTextInputFormatter(60)],
                    decoration: _dec(t('Colours', 'रंग'), hint: t('any', 'कोई भी')),
                  ),
                ),
                if (_oldRows.length > 1)
                  SizedBox(
                    width: 32,
                    child: IconButton(
                      padding: EdgeInsets.zero,
                      tooltip: t('Remove', 'हटाएँ'),
                      icon: const Icon(Icons.close_rounded, size: 20),
                      onPressed: () {
                        final gone = _oldRows[i];
                        setState(() => _oldRows.removeAt(i));
                        WidgetsBinding.instance.addPostFrameCallback((_) => gone.dispose());
                      },
                    ),
                  ),
              ]),
            ),
          if (_oldRows.length < _kMaxOldRows)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => setState(() => _oldRows.add(_OldRow())),
                icon: const Icon(Icons.add_circle_outline_rounded, size: 20),
                label: Text(t('Next design', 'अगला डिज़ाइन')),
              ),
            ),
        ],
      ]),
    );
  }

  InputDecoration _dec(String label,
          {String? hint,
          Widget? prefix,
          String? helper,
          Widget? suffix,
          Color? helperColor}) =>
      InputDecoration(
        labelText: label,
        hintText: hint,
        prefix: prefix,
        suffixIcon: suffix,
        helperText: helper,
        helperMaxLines: 2,
        helperStyle: helperColor == null ? null : TextStyle(color: helperColor),
        border: const OutlineInputBorder(),
        isDense: true,
      );

  @override
  Widget build(BuildContext context) {
    final photos = _orderPhotos();
    ref.watch(piecesProvider);
    final marks = ref.watch(marksProvider);
    final picks = ref.watch(picksProvider);
    final scheme = Theme.of(context).colorScheme;
    final edits = ref.watch(editsProvider);
    _readMarks(photos, edits);
    final pcs = photos.fold<int>(0, (s, p) => s + _qtyFor(p));
    final value = _check(photos);
    // Owner 21-Nov: a design that is not ready (picked in the "Design not in
    // app?" box) is a PRE ORDER — listed under the amount in its own block,
    // not among "Your designs".
    final ready = [for (final p in photos) if (!DriveUrls.isOld(p.id)) p];
    final pre = [for (final p in photos) if (DriveUrls.isOld(p.id)) p];
    final prePcs = pre.fold<int>(0, (s, p) => s + _qtyFor(p));

    // Booking place helper under the field.
    String? placeHelper;
    Color? placeColor;
    final info = _pinInfo;
    if (info != null && _bookingPlace.text.trim().isNotEmpty) {
      if (OrderService.placeMatches(_bookingPlace.text, info)) {
        placeHelper = '✓ Matches pincode (${info.label})';
        placeColor = const Color(0xFF2E7D32);
      } else {
        placeHelper = '⚠ Pincode is ${info.label} — please check';
        placeColor = Colors.orange.shade800;
      }
    }
    String? pinHelper;
    Color? pinColor;
    if (_india) {
      if (_pinChecking) {
        pinHelper = t('Checking pincode…', 'पिनकोड जाँच रहे हैं…');
      } else if (_pinNotFound) {
        pinHelper = '✗ This pincode does not exist';
        pinColor = scheme.error;
      } else if (info != null) {
        pinHelper = '📍 ${info.label}';
        pinColor = const Color(0xFF2E7D32);
      }
    }
    final kind = OrderService.taxIdKind(_taxId.text);

    Widget rowFor(Photo p, {bool preOrder = false}) =>
      _ItemRow(
        photo: p,
        preOrder: preOrder,
        qty: _qtyFor(p),
        edited: edits.containsKey(p.id),
        reading: ref.read(marksProvider.notifier).isReading(p.id),
        fromMarks:
            !_qty.containsKey(p.id) && marks.containsKey(p.id),
        pick: picks[p.id],
        sareeCount: ref.read(piecesProvider.notifier).piecesFor(p),
        pickLabel: _qty.containsKey(p.id)
            ? null
            : picks[p.id]?.label(
                ref.read(piecesProvider.notifier).piecesFor(p)),
        onOpenPick: () =>
            context.push('/pick/${Uri.encodeComponent(p.id)}'),
        onQty: (v) => setState(() {
          // Owner 12-Oct: below ₹310 = SET TO SET only — + / − move
          // by a whole set.
          final set = ref.read(piecesProvider.notifier).piecesFor(p);
          if (isSetOnly(p.price) && set != null && set > 0) {
            final cur = _qtyFor(p);
            final sets = (cur / set).round().clamp(1, 999);
            _qty[p.id] = (v > cur ? sets + 1 : (sets - 1).clamp(1, 999)) * set;
          } else {
            _qty[p.id] = v;
          }
        }),
        onRemove: () => setState(() => _excluded.add(p.id)),
      );

    return Scaffold(
      appBar: AppBar(
          title: UText(t('Place order', 'ऑर्डर करें'))),
      body: photos.isEmpty
          ? Center(child: UText(t('Your cart is empty.', 'कार्ट खाली है।')))
          : Form(
              key: _formKey,
              autovalidateMode: AutovalidateMode.onUserInteraction,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 24),
                children: [
                  _SectionTitle(t('1 · Your designs (${ready.length})', '1 · आपके डिज़ाइन (${ready.length})')),
                  const SizedBox(height: 4),
                  Text(
                      t('Pieces = sarees in the photo. Change with + / − if you want more or less.', 'पीस = फ़ोटो में जितनी साड़ियाँ। कम-ज़्यादा के लिए + / − दबाएँ।'),
                      style: Theme.of(context).textTheme.bodySmall),
                  const SizedBox(height: 8),
                  for (final p in ready) rowFor(p),
                  if (_excluded.isNotEmpty)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed: () => setState(_excluded.clear),
                        icon: const Icon(Icons.undo_rounded, size: 18),
                        label: Text(t('Bring back ${_excluded.length} removed', 'हटाए हुए ${_excluded.length} वापस लाएँ')),
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.only(top: 6, bottom: 8),
                    child: Text(
                        t('${ready.length} design${ready.length == 1 ? '' : 's'} · ${pcs - prePcs} pcs',
                            '${ready.length} डिज़ाइन · ${pcs - prePcs} पीस'),
                        style: const TextStyle(fontWeight: FontWeight.w700)),
                  ),
                  Builder(builder: (_) {
                    final parcel = OrderService.activeParcel(
                        ref.read(sharedPreferencesProvider), mobile: _mobileNow);
                    return MinOrderBar(
                        progress: value.progress,
                        below: value.below,
                        amount: value.known,
                        addOnTo: parcel == null ? null : 'ORDER NO. ${parcel.serial ?? '-'}',
                        addOnUntil: parcel == null
                            ? null
                            : '${OrderService.untilLabel(parcel.until)} (${parcel.left} of ${OrderService.kMaxAddOns} add-ons left)');
                  }),
                  if (value.below && OrderService.activeParcel(ref.read(sharedPreferencesProvider), mobile: _mobileNow) == null)
                    HotPicksRow(short: kMinOrderValue - value.known), // owner 27-Oct (4)
                  if (value.below)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed: () => context.go('/'),
                        icon: const Icon(Icons.add_photo_alternate_outlined),
                        label: Text(t('Select more designs', 'और डिज़ाइन चुनें')),
                      ),
                    ),
                  if (pre.isNotEmpty) ...[
                    const SizedBox(height: 14),
                    Container(
                      key: const ValueKey('pre-order-box'),
                      padding: const EdgeInsets.fromLTRB(12, 12, 2, 8),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFFF8E7),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: const Color(0xFFE0C98A)),
                      ),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        UText(t('Not ready designs — approx 2 weeks', 'जो डिज़ाइन तैयार नहीं — लगभग 2 हफ़्ते'),
                            style: const TextStyle(fontWeight: FontWeight.w800, letterSpacing: 0.8, fontSize: 13)),
                        const SizedBox(height: 2),
                        Padding(
                          padding: const EdgeInsets.only(right: 10),
                          child: Text(
                              t('Pre order: these goods are made for you and will be ready in approx 2 weeks.',
                                  'प्री ऑर्डर: यह माल आपके लिए बनेगा, लगभग 2 हफ़्ते में तैयार होगा।'),
                              style: const TextStyle(fontSize: 12.5, color: Colors.black87)),
                        ),
                        const SizedBox(height: 6),
                        for (final p in pre) rowFor(p, preOrder: true),
                        Padding(
                          padding: const EdgeInsets.only(top: 4, bottom: 2),
                          child: Text(
                              t('${pre.length} pre order design${pre.length == 1 ? '' : 's'} · $prePcs pcs',
                                  '${pre.length} प्री ऑर्डर डिज़ाइन · $prePcs पीस'),
                              style: const TextStyle(fontWeight: FontWeight.w700)),
                        ),
                      ]),
                    ),
                  ],
                  const SizedBox(height: 14),
                  _oldDesignBox(),
                  const SizedBox(height: 22),
                  Row(children: [
                    Expanded(child: _SectionTitle(t('2 · Your details', '2 · आपकी जानकारी'))),
                  ]),
                  if (_usingSaved && !_old)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(
                          t('Filled from your last details — check and send.', 'पिछली जानकारी से भरा है — जाँच कर भेजें।'),
                          style: Theme.of(context).textTheme.bodySmall),
                    ),
                  const SizedBox(height: 6),
                  // Outside India the form's own "Mobile No. (with country
                  // code)" is the only number box — no +91 search box on top.
                  if (_accMobile != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Row(children: [
                        const Icon(Icons.verified_rounded, color: Color(0xFF2E7D32), size: 20),
                        const SizedBox(width: 8),
                        Text('Mobile: +91 $_accMobile',
                            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
                        if (_looking) ...[
                          const SizedBox(width: 10),
                          const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                        ],
                      ]),
                    ),
                  if (_accMobile != null && _lookErr != null)
                    Text(_lookErr!, style: TextStyle(color: scheme.error, fontWeight: FontWeight.w600)),
                  if (_accMobile != null) ...[
                    for (final pt in _matches) _partyCard(pt, selectable: _matches.length > 1),
                    if (_party != null)
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton.icon(
                          onPressed: _editTransport,
                          icon: const Icon(Icons.local_shipping_outlined, size: 18),
                          label: const Text('EDIT TRANSPORT'),
                        ),
                      ),
                  ],
                  if (_accMobile == null && (_india || !_newForm)) ...[
                    Text('Type your mobile number — we find your account by ourselves.',
                        style: Theme.of(context).textTheme.bodySmall),
                    const SizedBox(height: 8),
                    Row(children: [
                      Expanded(
                        child: TextField(
                          controller: _oldMobile,
                          keyboardType: TextInputType.phone,
                          inputFormatters: [
                            FilteringTextInputFormatter.allow(RegExp(r'[0-9+ \-]')),
                            LengthLimitingTextInputFormatter(18),
                          ],
                          decoration: _dec('Mobile No. *', prefix: const Text('+91 ')),
                          onSubmitted: (_) => _findParty(),
                        ),
                      ),
                      const SizedBox(width: 10),
                      SizedBox(
                        height: 48,
                        child: FilledButton(
                          onPressed: _looking ? null : _findParty,
                          child: _looking
                              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                              : const Text('FIND'),
                        ),
                      ),
                    ]),
                    if (_lookErr != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(_lookErr!, style: TextStyle(color: scheme.error, fontWeight: FontWeight.w600)),
                      ),
                    if (_linked.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Wrap(spacing: 8, runSpacing: 8, children: [
                          for (final m in _linked)
                            ActionChip(
                              avatar: const Icon(Icons.phone_iphone_rounded, size: 18),
                              label: Text('+91 $m',
                                  style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
                              onPressed: () {
                                _oldMobile.text = m;
                                _findParty();
                              },
                            ),
                        ]),
                      ),
                    if (_matches.length > 1)
                      Padding(
                        padding: const EdgeInsets.only(top: 10),
                        child: Text('This number has ${_matches.length} parties — tap yours:',
                            style: const TextStyle(fontWeight: FontWeight.w700)),
                      ),
                    for (final pt in _matches) _partyCard(pt, selectable: _matches.length > 1),
                    if (_party != null)
                      const Padding(
                        padding: EdgeInsets.only(top: 8),
                        child: Text('✓ Your account is found — no need to fill anything.',
                            style: TextStyle(color: Color(0xFF2E7D32), fontWeight: FontWeight.w700)),
                      ),
                    if (_newForm && !_newFormForeign)
                      const Padding(
                        padding: EdgeInsets.only(top: 10, bottom: 6),
                        child: Text('New customer — please fill your details below.',
                            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
                      ),
                    if (!_newForm && _party == null)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton(
                          onPressed: () => setState(() {
                            _newForm = true;
                            _newFormForeign = true;
                            _country = 'Other';
                          }),
                          child: const Text('Customer outside India? Tap here'),
                        ),
                      ),
                  ],
                  if (_newForm) ...[
                  // Owner 12-Oct: GST first — a valid GST number fills the form
                  // from the GST portal (the customer can still change it).
                  // Owner 12-Oct: GST / PAN / Aadhaar only for Indian customers.
                  if (_india) ...[
                  TextFormField(
                    controller: _taxId,
                    textCapitalization: TextCapitalization.characters,
                    decoration: _dec(t('GST / PAN / Aadhaar *', 'GST / PAN / आधार *'),
                        helper: (kind != null && !kind.startsWith('!'))
                            ? '✓ $kind number'
                            : null,
                        helperColor: const Color(0xFF2E7D32)),
                    validator: (v) {
                      if ((v ?? '').trim().isEmpty) return 'Enter your GST, PAN or Aadhaar number';
                      if (_gstNote != null && !_gstOk) {
                        return 'GST not verified — please correct it';
                      }
                      final k = OrderService.taxIdKind(v ?? '');
                      return (k != null && k.startsWith('!'))
                          ? k.substring(1)
                          : null;
                    },
                  ),
                  if (_taxMatches.isNotEmpty) ...[
                    const Padding(
                      padding: EdgeInsets.only(top: 10),
                      child: Text('This GST / PAN is already with us — tap your account:',
                          style: TextStyle(fontWeight: FontWeight.w800, color: Color(0xFF2E7D32))),
                    ),
                    for (final pt in _taxMatches)
                      GestureDetector(onTap: () => _useAccount(pt), child: _partyCard(pt)),
                  ],
                  if (_gstNote != null && _taxMatches.isEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 6, left: 4),
                      child: Text(_gstNote!,
                          style: TextStyle(
                              fontWeight: FontWeight.w700,
                              color: _gstOk ? const Color(0xFF2E7D32) : const Color(0xFFD32F2F))),
                    ),
                  ],
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    key: ValueKey(_country),
                    initialValue: _country,
                    isExpanded: true,
                    decoration: _dec(t('Country', 'देश')),
                    items: [
                      for (final c in OrderService.countries)
                        DropdownMenuItem(value: c, child: Text(c)),
                    ],
                    onChanged: (v) => setState(() {
                      _country = v ?? 'India';
                      if (_country == 'India' && _newFormForeign) {
                        // Tester 13-Oct: back to India → the mobile search
                        // box again (a foreign number is no Indian number).
                        _newFormForeign = false;
                        _newForm = false;
                        _mobile.clear();
                        _party = null;
                        _matches = [];
                        _searched = null;
                      }
                      if (_country != 'India') {
                        _taxId.clear(); // no GST / PAN / Aadhaar abroad
                        _gstNote = null;
                        _gstLooked = null;
                        _taxMatches = [];
                      }
                      _pinInfo = null;
                      _pinNotFound = false;
                      _onPinChanged();
                    }),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _billName,
                    textCapitalization: TextCapitalization.characters,
                    decoration: _dec(t('Bill Name *', 'बिल का नाम *'), hint: t('Firm / party name', 'फर्म / पार्टी का नाम')),
                    validator: (v) =>
                        (v ?? '').trim().length < 2 ? t('Enter bill name', 'बिल का नाम लिखें') : null,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _address,
                    minLines: 2,
                    maxLines: 4,
                    textCapitalization: TextCapitalization.words,
                    decoration: _dec(t('Address *', 'पता *')),
                    validator: (v) => (v ?? '').trim().length < 5
                        ? t('Enter full address', 'पूरा पता लिखें')
                        : null,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _pincode,
                    keyboardType:
                        _india ? TextInputType.number : TextInputType.text,
                    inputFormatters: _india
                        ? [
                            FilteringTextInputFormatter.digitsOnly,
                            LengthLimitingTextInputFormatter(6)
                          ]
                        : null,
                    decoration: _dec(_india ? t('Pincode *', 'पिनकोड *') : 'Postal Code *',
                        helper: pinHelper, helperColor: pinColor),
                    validator: (v) =>
                        OrderService.validatePincode(v ?? '', india: _india),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _bookingPlace,
                    textCapitalization: TextCapitalization.characters,
                    decoration: _dec(_india ? t('Booking Place *', 'बुकिंग स्थान *') : 'City *',
                        hint: _india
                            ? t('City where goods are booked', 'जिस शहर में माल बुक होगा')
                            : 'Your city',
                        helper: placeHelper,
                        helperColor: placeColor),
                    validator: (v) => (v ?? '').trim().length < 2
                        ? t('Enter booking place', 'बुकिंग स्थान लिखें')
                        : null,
                  ),
                  const SizedBox(height: 12),
                  if (!_india) TextFormField(
                    controller: _mobile,
                    keyboardType: TextInputType.phone,
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(RegExp(r'[0-9+ \-]')),
                      LengthLimitingTextInputFormatter(18),
                    ],
                    decoration: _dec(t('Mobile No. *', 'मोबाइल नंबर *'),
                        hint: _india ? t('10-digit mobile', '10 अंक का मोबाइल') : t('With country code', 'देश कोड के साथ'),
                        prefix: _india ? const Text('+91 ') : null),
                    validator: (v) =>
                        OrderService.validateMobile(v ?? '', india: _india),
                  ),
                  const SizedBox(height: 12),
                  // Abroad: their own shipping / cargo company, typed freely
                  // (Indian transport list and suggestions don't apply).
                  if (!_india)
                    TextFormField(
                      controller: _transport,
                      textCapitalization: TextCapitalization.characters,
                      decoration: _dec('Shipping / Cargo company (optional)',
                          hint: 'e.g. your cargo agent in India',
                          suffix: const Icon(Icons.flight_takeoff_rounded)),
                    ),
                  if (_india)
                  _TransportField(
                    controller: _transport,
                    focusNode: _transportFocus,
                    options: _transports,
                    info: _tInfo,
                    place: _bookingPlace.text,
                    decoration: _dec(t('Transport Name', 'ट्रांसपोर्ट का नाम'),
                        hint: t('Type and choose from the list', 'लिखें और लिस्ट में से चुनें'),
                        suffix: const Icon(Icons.local_shipping_outlined)),
                    validator: (v) => (v ?? '').trim().length < 2
                        ? 'Choose your transport'
                        : (TransportInfo.ok(_tInfo, _transports, v ?? '') ? null : 'Please choose your transport from the list'),
                  ),
                  if (_india)
                  _TransportHelp(
                    info: _tInfo,
                    place: _bookingPlace.text,
                    transport: _transport.text,
                    onPick: (t) {
                      _transport.text = t;
                      _transportFocus.unfocus();
                    },
                  ),
                  const SizedBox(height: 12),
                  ],
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _note,
                    minLines: 1,
                    maxLines: 4,
                    decoration: _dec(t('Any special request or note — please type here', 'कोई खास रिक्वेस्ट या नोट — यहाँ लिखें'),
                        hint: t('Colour, delivery date, packing…', 'रंग, डिलीवरी तारीख, पैकिंग…')),
                  ),
                  const SizedBox(height: 18),
                ],
              ),
            ),
      bottomNavigationBar: photos.isEmpty
          ? null
          : Material(
              elevation: 8,
              color: scheme.surface,
              child: SafeArea(
                top: false,
                minimum: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                child: SizedBox(
                  height: 52,
                  child: FilledButton.icon(
                    onPressed: (_sending || _submitting)
                        ? null
                        : (value.below
                            ? () => context.go('/')
                            : () => _submit(photos)),
                    icon: Icon(value.below
                        ? Icons.add_photo_alternate_outlined
                        : Icons.check_circle_outline_rounded),
                    label: UText(
                      value.below
                          ? t('First complete ${MinOrderBar.minLabel} — select more', 'पहले ${MinOrderBar.minLabel} पूरा करें — और चुनें')
                          : t('Place order · ${photos.length} design${photos.length == 1 ? '' : 's'} · $pcs pcs', 'ऑर्डर भेजें · ${photos.length} डिज़ाइन · $pcs पीस'),
                      style: const TextStyle(
                          fontWeight: FontWeight.w700, letterSpacing: 0.4),
                    ),
                  ),
                ),
              ),
            ),
    );
  }
}

/// One typed row of the "Designs not in app" box.
class _OldRow {
  final design = TextEditingController();
  final qty = TextEditingController();
  final colours = TextEditingController();
  void dispose() {
    design.dispose();
    qty.dispose();
    colours.dispose();
  }
}

class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);
  @override
  Widget build(BuildContext context) => UText(text,
      style: const TextStyle(
          fontWeight: FontWeight.w800, letterSpacing: 0.8, fontSize: 13));
}

class _ItemRow extends StatelessWidget {
  final Photo photo;
  final int qty;
  final bool edited;
  final bool reading;
  final bool fromMarks;
  final String? pickLabel;
  final PickState? pick;
  final int? sareeCount;
  final VoidCallback? onOpenPick;
  final ValueChanged<int> onQty;
  final VoidCallback onRemove;

  /// A design that is not ready (ordered from the shop's full photo set).
  final bool preOrder;
  const _ItemRow({
    required this.photo,
    this.preOrder = false,
    required this.qty,
    required this.edited,
    this.reading = false,
    this.fromMarks = false,
    this.pickLabel,
    this.pick,
    this.sareeCount,
    this.onOpenPick,
    required this.onQty,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final folder =
        photo.folder.split('/').where((s) => s.isNotEmpty).join(' › ');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          GestureDetector(
            onTap: onOpenPick,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                width: 58,
                height: 72,
                child: Stack(fit: StackFit.expand, children: [
                  if (pick != null && !pick!.isEmpty)
                    PickPreviewImage(photo: photo, pick: pick!, decodeWidth: 200, sareeCount: sareeCount)
                  else
                  CachedNetworkImage(
                    imageUrl: photo.thumbUrl(),
                    cacheManager: photoCacheManager,
                    memCacheWidth: 180,
                    fit: BoxFit.cover,
                    errorWidget: (_, __, ___) =>
                        Container(color: scheme.surfaceContainerHighest),
                  ),
                  if (edited)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: Container(
                        color: Colors.black54,
                        padding: const EdgeInsets.symmetric(vertical: 1),
                        child: const Text('✎ marked',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: Colors.white, fontSize: 9)),
                      ),
                    ),
                ]),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Flexible(
                    child: Text(
                      photo.designNumber != null
                          ? 'D.No ${photo.designNumber}'
                          : photo.filename,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                  if (preOrder) ...[
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                          color: const Color(0xFF8A4B00), borderRadius: BorderRadius.circular(6)),
                      child: const Text('PRE ORDER',
                          style: TextStyle(
                              color: Colors.white, fontSize: 10, fontWeight: FontWeight.w800, letterSpacing: 0.6)),
                    ),
                  ],
                ]),
                if (photo.price != null)
                  Text('₹${photo.price}',
                      style: TextStyle(color: scheme.onSurfaceVariant)),
                if (preOrder)
                  Text(t('Not ready · approx 2 weeks', 'तैयार नहीं · लगभग 2 हफ़्ते'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall)
                else if (folder.isNotEmpty)
                  Text(folder,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall),
                if (pickLabel != null)
                  Text('✓ $pickLabel',
                      style: const TextStyle(
                          fontSize: 11, color: Color(0xFF2E7D32)))
                else if (reading)
                  Text(t('Reading your marks…', 'निशान पढ़ रहे हैं…'),
                      style: TextStyle(fontSize: 11, color: scheme.primary))
                else if (fromMarks)
                  Text(t('✓ Pieces from your marks', '✓ आपके निशान से पीस'),
                      style: TextStyle(fontSize: 11, color: Color(0xFF2E7D32))),
              ],
            ),
          ),
          _Stepper(value: qty, onChanged: onQty),
          IconButton(
            tooltip: t('Remove from this order', 'इस ऑर्डर से हटाएँ'),
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.close_rounded, size: 20),
            onPressed: onRemove,
          ),
        ],
      ),
    );
  }
}

class _Stepper extends StatelessWidget {
  final int value;
  final ValueChanged<int> onChanged;
  const _Stepper({required this.value, required this.onChanged});

  Future<void> _typeQty(BuildContext context) async {
    final ctrl = TextEditingController(text: '$value');
    final v = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t('Pieces', 'पीस')),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          keyboardType: TextInputType.number,
          inputFormatters: [
            FilteringTextInputFormatter.digitsOnly,
            LengthLimitingTextInputFormatter(4)
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: Text(t('Cancel', 'रद्द करें'))),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, int.tryParse(ctrl.text)),
              child: const Text('OK')),
        ],
      ),
    );
    if (v != null && v >= 0) onChanged(v);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        InkWell(
          onTap: value > 0 ? () => onChanged(value - 1) : null,
          child: const Padding(
              padding: EdgeInsets.all(6), child: Icon(Icons.remove, size: 18)),
        ),
        InkWell(
          onTap: () => _typeQty(context),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 26),
            child: Text('$value',
                textAlign: TextAlign.center,
                style: const TextStyle(fontWeight: FontWeight.w800)),
          ),
        ),
        InkWell(
          onTap: () => onChanged(value + 1),
          child: const Padding(
              padding: EdgeInsets.all(6), child: Icon(Icons.add, size: 18)),
        ),
      ]),
    );
  }
}

/// Searchable transport picker that also accepts a typed name.
class _TransportField extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final List<String> options;
  final InputDecoration decoration;
  final FormFieldValidator<String>? validator;
  final TransportInfo? info;
  final String place;
  const _TransportField({
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
        // Owner 16-Oct: pick-only list (GST transporters + COURIER + TRAVELS).
        final options = info?.choices(this.options) ?? this.options;
        if (q.isEmpty) {
          // Transports the shop's parties use for this place come first.
          final usual = [for (final e in info?.forPlace(place) ?? const <(String, int)>[]) e.$1];
          final ok = usual.where(options.contains).toList();
          return [...ok, ...options.where((o) => !ok.contains(o))].take(40);
        }
        return TransportInfo.search(options, q);
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
                  maxHeight: 260,
                  maxWidth: MediaQuery.of(context).size.width - 28),
              child: ListView.builder(
                padding: EdgeInsets.zero,
                shrinkWrap: true,
                itemCount: list.length,
                itemBuilder: (_, i) {
                  final g = info?.gstOf(list[i]);
                  return ListTile(
                    dense: true,
                    title: Text(list[i]),
                    // Owner: GST no. beside the name so a new party isn't confused.
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


/// Under the transport box: the chosen transport's GST no. + where it goes,
/// and the transports the shop's parties use for the booking place.
class _TransportHelp extends StatelessWidget {
  final TransportInfo? info;
  final String place, transport;
  final ValueChanged<String> onPick;
  const _TransportHelp(
      {required this.info, required this.place, required this.transport, required this.onPick});

  @override
  Widget build(BuildContext context) {
    final i = info;
    if (i == null) return const SizedBox.shrink();
    final gst = transport.trim().isEmpty ? null : i.gstOf(transport);
    final goes = transport.trim().isEmpty ? const <(String, int)>[] : i.placesOf(transport);
    final usual = i.forPlace(place);
    const green = Color(0xFF1B5E20);
    if (gst == null && goes.isEmpty && usual.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 6, 4, 0),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (gst != null)
          Text('✓ GST no. of this transport: $gst',
              style: const TextStyle(fontWeight: FontWeight.w800, color: green)),
        if (goes.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text('Our parties use it for: ${goes.take(8).map((e) => e.$1).join(', ')}',
                style: const TextStyle(fontSize: 12, color: Colors.black54)),
          ),
        if (usual.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text('Suggestion of transports going to ${place.trim().toUpperCase()} — tap to choose:',
              style: const TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          Wrap(spacing: 6, runSpacing: 4, children: [
            for (final e in usual.take(8))
              ActionChip(
                visualDensity: VisualDensity.compact,
                label: Text(e.$1, style: const TextStyle(fontSize: 12)),
                onPressed: () => onPick(e.$1),
              ),
          ]),
        ],
      ]),
    );
  }
}
