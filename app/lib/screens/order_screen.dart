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
import '../services/order_service.dart';
import '../services/transport_info.dart';
import '../services/phone_lock.dart';
import '../services/photo_freshness.dart';
import '../services/marks_service.dart';
import '../services/picks_service.dart';
import '../services/pieces_service.dart';
import '../widgets/min_order_bar.dart';
import '../widgets/pick_preview.dart';

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

  @override
  void initState() {
    super.initState();
    final saved =
        OrderService.savedCustomer(ref.read(sharedPreferencesProvider));
    if (saved != null) {
      _fill(saved);
      _usingSaved = true;
      _old = saved.kind == 'old';
      _oldMobile.text = saved.mobile;
      if (!_old) {
        _newForm = true;
        _searched = OrderService.normalizeIndianMobile(saved.mobile);
      }
    }
    _oldMobile.addListener(_onMobileTyped);
    _taxId.addListener(_onTaxTyped);
    if (_old && saved != null) {
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
    final r = await OrderService.gstLookup(ref.read(dioProvider), g);
    if (!mounted || _gstLooked != g) return;
    if (r == null || r['found'] != true) {
      final why = r?['reason'];
      setState(() {
        // Owner 12-Oct: GST not verified → remove it; goods can be taken
        // without GST.
        _gstOk = false;
        _gstNote = '✗ This GST number could not be verified. Please correct it, '
            'or remove it — you can order without GST.';
      });
      return;
    }
    final status = '${r['status'] ?? ''}';
    final name = '${r['tradeName'] ?? ''}'.isNotEmpty ? '${r['tradeName']}' : '${r['legalName'] ?? ''}';
    setState(() {
      if (name.isNotEmpty) _billName.text = name;
      if ('${r['address'] ?? ''}'.isNotEmpty) _address.text = '${r['address']}';
      if ('${r['pin'] ?? ''}'.isNotEmpty) _pincode.text = '${r['pin']}';
      if ('${r['city'] ?? ''}'.isNotEmpty && _bookingPlace.text.trim().isEmpty) {
        _bookingPlace.text = '${r['city']}';
      }
      _gstOk = status.toLowerCase() == 'active' || status.isEmpty;
      _gstNote = _gstOk
          ? '✓ GST verified — ${r['legalName']}. Details filled; change anything if needed.'
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
    final mob = '${pt['mobile'] ?? ''}';
    setState(() {
      _searched = OrderService.normalizeIndianMobile(mob) ?? _searched;
      if (mob.isNotEmpty) _oldMobile.text = mob;
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
    if (!lock.allowed) {
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
        _newForm = list.isEmpty; // not with us → the new-customer form
        if (list.isEmpty) _mobile.text = m;
      });
    } catch (_) {
      if (mounted) setState(() => _lookErr = 'No internet — please try again.');
    } finally {
      if (mounted) setState(() => _looking = false);
    }
  }

  Widget _partyCard(Map<String, dynamic> pt, {bool selectable = false}) {
    String v(String k) => '${pt[k] ?? ''}'.trim();
    final lines = <String>[
      if (v('address').isNotEmpty) v('address'),
      [v('dest'), v('pincode')].where((s) => s.isNotEmpty).join(' - '),
      if (v('transport').isNotEmpty) 'Transport: ${v('transport')}',
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
        onTap: selectable ? () => setState(() => _party = pt) : null,
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
    for (final c in [
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
    // Add-on window open → no minimum.
    if (OrderService.activeParcel(ref.read(sharedPreferencesProvider)) != null) {
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

  Future<void> _submit(List<Photo> photos) async {
    if (_sending || photos.isEmpty) return;
    FocusScope.of(context).unfocus();
    final marks = ref.read(marksProvider.notifier);
    if (photos.any((p) => marks.isReading(p.id))) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(t('Reading your marks on the photos — one moment…', 'फ़ोटो पढ़ रहे हैं — एक पल…'))));
      return;
    }
    if (_check(photos).below) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(t('Minimum order is ${MinOrderBar.minLabel}. Please select a few more designs.',
              'कम से कम ${MinOrderBar.minLabel} का ऑर्डर होना चाहिए। कुछ और डिज़ाइन चुनें।'))));
      return;
    }
    if (!_newForm) {
      if (_party == null) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Type your 10-digit mobile number first.')));
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
      transport: v('transport'),
      taxId: v('gstin'),
    );
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
        OrderService.activeParcel(ref.read(sharedPreferencesProvider)) == null) {
      if (!await _newPartyCheck(customer) || !mounted) return;
    }
    final lockNote = [
      if (lock.newPhone) '⚠️ NEW PHONE for this number',
      if (lock.index == 2) '⚠️ 2nd number on this phone (1st: ${lock.first ?? '-'})',
    ].join('\n');
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
        lockNote: _lockNote,
        onStep: (s) => step.value = s,
        // Owner 12-Oct: NEW Indian customer pays a 10% advance first.
        holdForAdvance: customer.kind != 'old' &&
            customer.isIndia &&
            OrderService.activeParcel(ref.read(sharedPreferencesProvider)) == null,
      );
    } catch (e) {
      order = null;
    }
    if (!mounted) return;
    Navigator.of(context, rootNavigator: true).pop(); // progress dialog
    setState(() => _sending = false);

    if (order == null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(t('Could not place the order. Please try again.', 'ऑर्डर नहीं हुआ, फिर से कोशिश करें।'))));
      return;
    }
    HapticFeedback.mediumImpact();
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
                  _SectionTitle(t('1 · Your designs (${photos.length})', '1 · आपके डिज़ाइन (${photos.length})')),
                  const SizedBox(height: 4),
                  Text(
                      t('Pieces = sarees in the photo. Change with + / − if you want more or less.', 'पीस = फ़ोटो में जितनी साड़ियाँ। कम-ज़्यादा के लिए + / − दबाएँ।'),
                      style: Theme.of(context).textTheme.bodySmall),
                  const SizedBox(height: 8),
                  for (final p in photos)
                    _ItemRow(
                      photo: p,
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
                    ),
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
                    child: Text(t('${photos.length} designs · $pcs pcs', '${photos.length} डिज़ाइन · $pcs पीस'),
                        style: const TextStyle(fontWeight: FontWeight.w700)),
                  ),
                  Builder(builder: (_) {
                    final parcel = OrderService.activeParcel(
                        ref.read(sharedPreferencesProvider));
                    return MinOrderBar(
                        progress: value.progress,
                        below: value.below,
                        amount: value.known,
                        addOnTo: parcel == null ? null : 'ORDER NO. ${parcel.serial ?? '-'}',
                        addOnUntil: parcel == null
                            ? null
                            : '${OrderService.untilLabel(parcel.until)} (${parcel.left} of ${OrderService.kMaxAddOns} add-ons left)');
                  }),
                  if (value.below)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed: () => context.go('/'),
                        icon: const Icon(Icons.add_photo_alternate_outlined),
                        label: Text(t('Select more designs', 'और डिज़ाइन चुनें')),
                      ),
                    ),
                  const SizedBox(height: 22),
                  Row(children: [
                    Expanded(child: _SectionTitle(t('2 · Your details', '2 · आपकी जानकारी'))),
                    if (_usingSaved && !_old)
                      TextButton(
                          onPressed: _clearSaved,
                          child: Text(t('New party', 'नई पार्टी'))),
                  ]),
                  if (_usingSaved && !_old)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(
                          t('Filled from your last order — check and send.', 'पिछले ऑर्डर से भरा है — जाँच कर भेजें।'),
                          style: Theme.of(context).textTheme.bodySmall),
                    ),
                  const SizedBox(height: 6),
                  ...[
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
                    decoration: _dec(t('GST / PAN / Aadhaar (optional)', 'GST / PAN / आधार (ज़रूरी नहीं)'),
                        helper: (kind != null && !kind.startsWith('!'))
                            ? '✓ $kind number'
                            : null,
                        helperColor: const Color(0xFF2E7D32)),
                    validator: (v) {
                      if (_gstNote != null && !_gstOk) {
                        return 'GST not verified — correct it or remove it (you can order without GST)';
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
                  if (_gstNote != null)
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
                        hint: t('Search or type your own', 'खोजें या खुद लिखें'),
                        suffix: const Icon(Icons.local_shipping_outlined)),
                    validator: (v) => (v ?? '').trim().length < 2
                        ? 'Enter transport name'
                        : null,
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
                    decoration: _dec(t('Message for us (optional)', 'हमारे लिए संदेश (ज़रूरी नहीं)'),
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
                    onPressed: _sending
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
                          : t('Place order · ${photos.length} designs · $pcs pcs', 'ऑर्डर भेजें · ${photos.length} डिज़ाइन · $pcs पीस'),
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
  const _ItemRow({
    required this.photo,
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
                Text(
                  photo.designNumber != null
                      ? 'D.No ${photo.designNumber}'
                      : photo.filename,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                if (photo.price != null)
                  Text('₹${photo.price}',
                      style: TextStyle(color: scheme.onSurfaceVariant)),
                if (folder.isNotEmpty)
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
        if (q.isEmpty) {
          // Transports the shop's parties use for this place come first.
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
