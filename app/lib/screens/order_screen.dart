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
  List<Map<String, dynamic>> _matches = [];
  Map<String, dynamic>? _party;

  // Pincode check state.
  PincodeInfo? _pinInfo;
  bool _pinChecking = false;
  bool _pinNotFound = false;
  Timer? _pinDebounce;

  List<String> _transports = const [];
  bool _sending = false;

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
      if (_old) _oldMobile.text = saved.mobile;
    }
    OrderService.transports().then((t) {
      if (mounted) setState(() => _transports = t);
    });
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
    });
    try {
      final list = await OrderService.lookupParty(ref.read(dioProvider), m);
      if (!mounted) return;
      setState(() {
        _matches = list;
        if (list.length == 1) _party = list.first;
        if (list.isEmpty) {
          _lookErr = 'This number is not in our records. Please choose NEW CUSTOMER.';
        }
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
    if (_old) {
      if (_party == null) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Enter your mobile number and tap FIND first.')));
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

  Future<void> _send(List<Photo> photos, CustomerDetails customer) async {
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
        onStep: (s) => step.value = s,
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
    final clear = await _showDone(order);
    if (!mounted) return;
    if (clear == true) {
      await ref.read(favoritesProvider.notifier).clear();
    }
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
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(t('Keep cart', 'कार्ट रखें'))),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(t('Empty cart', 'कार्ट खाली करें'))),
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
                      onQty: (v) => setState(() => _qty[p.id] = v),
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
                        addOnTo: parcel?.number,
                        addOnUntil: parcel == null
                            ? null
                            : OrderService.untilLabel(parcel.until));
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
                  SizedBox(
                    width: double.infinity,
                    child: SegmentedButton<bool>(
                      segments: const [
                        ButtonSegment(value: true, label: Text('OLD CUSTOMER'), icon: Icon(Icons.storefront_rounded)),
                        ButtonSegment(value: false, label: Text('NEW CUSTOMER'), icon: Icon(Icons.person_add_alt_1_rounded)),
                      ],
                      selected: {_old},
                      onSelectionChanged: (v) => setState(() => _old = v.first),
                    ),
                  ),
                  const SizedBox(height: 14),
                  if (_old) ...[
                    Text('Type your mobile number — we will fill your details.',
                        style: Theme.of(context).textTheme.bodySmall),
                    const SizedBox(height: 8),
                    Row(children: [
                      Expanded(
                        child: TextField(
                          controller: _oldMobile,
                          keyboardType: TextInputType.phone,
                          inputFormatters: [
                            FilteringTextInputFormatter.allow(RegExp(r'[0-9+ ]')),
                            LengthLimitingTextInputFormatter(14),
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
                    if (_matches.length > 1)
                      Padding(
                        padding: const EdgeInsets.only(top: 10),
                        child: Text('This number has ${_matches.length} parties — tap yours:',
                            style: const TextStyle(fontWeight: FontWeight.w700)),
                      ),
                    for (final pt in _matches) _partyCard(pt, selectable: _matches.length > 1),
                  ],
                  if (!_old) ...[
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
                    decoration: _dec(t('Booking Place *', 'बुकिंग स्थान *'),
                        hint: t('City where goods are booked', 'जिस शहर में माल बुक होगा'),
                        helper: placeHelper,
                        helperColor: placeColor),
                    validator: (v) => (v ?? '').trim().length < 2
                        ? t('Enter booking place', 'बुकिंग स्थान लिखें')
                        : null,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
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
                  _TransportField(
                    controller: _transport,
                    focusNode: _transportFocus,
                    options: _transports,
                    decoration: _dec(t('Transport Name', 'ट्रांसपोर्ट का नाम'),
                        hint: t('Search or type your own', 'खोजें या खुद लिखें'),
                        suffix: const Icon(Icons.local_shipping_outlined)),
                    validator: (v) => (v ?? '').trim().length < 2
                        ? 'Enter transport name'
                        : null,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _taxId,
                    textCapitalization: TextCapitalization.characters,
                    decoration: _dec(t('GST / PAN / Aadhaar (optional)', 'GST / PAN / आधार (ज़रूरी नहीं)'),
                        helper: (kind != null && !kind.startsWith('!'))
                            ? '✓ $kind number'
                            : null,
                        helperColor: const Color(0xFF2E7D32)),
                    validator: (v) {
                      final k = OrderService.taxIdKind(v ?? '');
                      return (k != null && k.startsWith('!'))
                          ? k.substring(1)
                          : null;
                    },
                  ),
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
  const _TransportField({
    required this.controller,
    required this.focusNode,
    required this.options,
    required this.decoration,
    this.validator,
  });

  @override
  Widget build(BuildContext context) {
    return RawAutocomplete<String>(
      textEditingController: controller,
      focusNode: focusNode,
      optionsBuilder: (v) {
        final q = v.text.trim().toUpperCase();
        if (q.isEmpty) return options.take(40);
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
                itemBuilder: (_, i) => ListTile(
                  dense: true,
                  title: Text(list[i]),
                  onTap: () => onSelected(list[i]),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
