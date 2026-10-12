import 'dart:async';
import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:catalog_app/widgets/caps_text.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../l10n.dart';

import '../models/photo.dart';
import '../providers/providers.dart';
import '../widgets/bar_button.dart';
import '../services/photo_freshness.dart';
import '../services/picks_service.dart';
import '../services/pieces_service.dart';

/// TAP-TO-SELECT: tap a saree = +1 of that colour, tap the background = +1 SET
/// (one of every colour), long-press a number = pick / type any quantity.
class PickScreen extends ConsumerStatefulWidget {
  final String photoId;
  const PickScreen({super.key, required this.photoId});

  @override
  ConsumerState<PickScreen> createState() => _PickScreenState();
}

class _PickScreenState extends ConsumerState<PickScreen> {
  PickState _s = const PickState();
  final List<PickState> _undo = [];
  double? _aspect; // width / height of the photo
  bool _crossMode = false; // ✕: tap a colour = do NOT send it
  List<List<int>>? _points;

  @override
  void initState() {
    super.initState();
    _s = ref.read(picksProvider)[widget.photoId] ?? const PickState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _guideOnce());
  }

  /// First time only: a big, simple picture-guide of how to select.
  Future<void> _guideOnce() async {
    final prefs = ref.read(sharedPreferencesProvider);
    if (prefs.getBool('pick_guide_v1') == true || !mounted) return;
    await prefs.setBool('pick_guide_v1', true);
    if (!mounted) return;
    Widget row(String icon, String text) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(children: [
            Text(icon, style: const TextStyle(fontSize: 30)),
            const SizedBox(width: 14),
            Expanded(child: Text(text, style: const TextStyle(fontSize: 17, height: 1.3))),
          ]),
        );
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t('How to select', 'कैसे चुनें'), textAlign: TextAlign.center),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          row('👆', t('Tap the saree colour you want = 1 piece', 'जो रंग चाहिए उस साड़ी पर टैप करें = 1 पीस')),
          row('👆👆', t('Tap again = 2, 3, 4…', 'फिर टैप करें = 2, 3, 4…')),
          row('✋', t('Hold a number = type any quantity', 'नंबर दबाकर रखें = कोई भी संख्या लिखें')),
          row('➕', t('SET + below = one of EVERY colour', 'नीचे SET + = हर रंग का एक पीस')),
          row('✅', t('Press DONE', 'आखिर में "हो गया" दबाएँ')),
        ]),
        actions: [
          SizedBox(
            width: double.infinity,
            height: 50,
            child: FilledButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(t('OK, start', 'ठीक है, शुरू करें'), style: const TextStyle(fontSize: 18)),
            ),
          ),
        ],
      ),
    );
  }

  Photo? get _photo =>
      ref.read(photosProvider).where((p) => p.id == widget.photoId).firstOrNull;

  void _resolveAspect(ImageProvider img) {
    if (_aspect != null) return;
    final stream = img.resolve(const ImageConfiguration());
    late ImageStreamListener l;
    l = ImageStreamListener((info, _) {
      if (mounted) {
        setState(() => _aspect = info.image.width / info.image.height);
      }
      stream.removeListener(l);
    }, onError: (_, __) => stream.removeListener(l));
    stream.addListener(l);
  }

  void _push(PickState next) {
    HapticFeedback.selectionClick();
    setState(() {
      _undo.add(_s);
      _s = next;
    });
  }

  /// Which detected saree (index) contains the point, preferring the one whose
  /// centre is nearest (folded sarees overlap).
  int? _hitBox(List<List<int>>? boxes, double x, double y) {
    if (boxes == null) return null;
    int? best;
    var bestD = double.infinity;
    for (var i = 0; i < boxes.length; i++) {
      final b = boxes[i]; // ymin xmin ymax xmax (0-1000)
      final y0 = b[0] / 1000,
          x0 = b[1] / 1000,
          y1 = b[2] / 1000,
          x1 = b[3] / 1000;
      if (x < x0 || x > x1 || y < y0 || y > y1) continue;
      final cx = (x0 + x1) / 2, cy = (y0 + y1) / 2;
      // Owner 12-Oct: when boxes overlap, the saree lying IN FRONT (starts
      // lower in the photo, smaller) wins — not the open one behind it.
      final d = (cx - x) * (cx - x) + (cy - y) * (cy - y) - y0 * 0.5 + (x1 - x0) * (y1 - y0) * 0.3;
      if (d < bestD) {
        bestD = d;
        best = i;
      }
    }
    return best;
  }

  int? _markAt(double x, double y, double radius) {
    for (var i = 0; i < _s.marks.length; i++) {
      final m = _s.marks[i];
      if (math.sqrt(math.pow(m.x - x, 2) + math.pow(m.y - y, 2)) < radius)
        return i;
    }
    return null;
  }

  /// Where a saree's number goes (owner: in the MIDDLE of the saree's own
  /// visible part — never on a border or an edge).
  ///
  /// Sarees lower in the photo lie IN FRONT of the ones above them, so the
  /// visible part of saree i = its box minus the boxes in front. The number
  /// goes at the centre of the biggest visible part (point farthest from any
  /// hidden area or edge). The AI's label point is used only when it falls
  /// well inside that visible part.
  Offset _labelSpot(int i, List<List<int>> boxes, List<List<int>>? points) {
    final b = boxes[i];
    const n = 24;
    final bw = (b[3] - b[1]).toDouble(), bh = (b[2] - b[0]).toDouble();
    bool hidden(double x, double y) {
      for (var j = 0; j < boxes.length; j++) {
        if (j == i) continue;
        final o = boxes[j];
        final inFront = o[0] > b[0] + 5; // starts lower → lies on top
        if (inFront && x >= o[1] && x <= o[3] && y >= o[0] && y <= o[2]) {
          return true;
        }
      }
      return false;
    }

    // Grid of visible cells, then distance (in cells) to the nearest hidden
    // cell or box edge — the max is the centre of the largest visible area.
    final vis = List.generate(n, (gy) => List.generate(n, (gx) {
          final x = b[1] + bw * (gx + 0.5) / n;
          final y = b[0] + bh * (gy + 0.5) / n;
          return !hidden(x, y);
        }));
    var best = Offset((b[1] + b[3]) / 2000, (b[0] + b[2]) / 2000);
    var bestD = -1.0;
    for (var gy = 0; gy < n; gy++) {
      for (var gx = 0; gx < n; gx++) {
        if (!vis[gy][gx]) continue;
        // distance to box edge, scaled to real proportions
        var d = math.min(math.min(gx + 0.5, n - gx - 0.5) * bw,
                math.min(gy + 0.5, n - gy - 0.5) * bh) /
            n;
        for (var yy = 0; yy < n && d > 0; yy++) {
          for (var xx = 0; xx < n; xx++) {
            if (vis[yy][xx]) continue;
            final dx = (xx - gx) * bw / n, dy = (yy - gy) * bh / n;
            final dd = math.sqrt(dx * dx + dy * dy);
            if (dd < d) d = dd;
          }
        }
        // Owner 12-Oct: an open saree lying behind the folded ones shows as
        // a band on top + a sliver at the side — the number belongs in the
        // MIDDLE of the saree, so spots near the left/right edge count less.
        final off = ((gx + 0.5) / n - 0.5).abs() * 2; // 0 middle … 1 edge
        d *= 1 - 0.6 * off;
        if (d > bestD) {
          bestD = d;
          best = Offset((b[1] + bw * (gx + 0.5) / n) / 1000,
              (b[0] + bh * (gy + 0.5) / n) / 1000);
        }
      }
    }
    // The AI's point wins only if it sits well inside the visible part.
    if (points != null && i < points.length && points[i].length == 2) {
      final px = points[i][1].toDouble(), py = points[i][0].toDouble();
      final gx = ((px - b[1]) / bw * n).floor(), gy = ((py - b[0]) / bh * n).floor();
      if (gx >= 1 && gy >= 1 && gx < n - 1 && gy < n - 1 && !hidden(px, py)) {
        var ok = true;
        for (var dy = -1; dy <= 1 && ok; dy++) {
          for (var dx = -1; dx <= 1; dx++) {
            if (!vis[gy + dy][gx + dx]) {
              ok = false;
              break;
            }
          }
        }
        final close = (Offset(px / 1000, py / 1000) - best).distance <
            0.35 * math.max(bw, bh) / 1000;
        if (ok && close) return Offset(px / 1000, py / 1000);
      }
    }
    return best;
  }

  bool get _setOnly => isSetOnly(_photo?.price);

  void _setOnlyNote() {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(
          content: Text('This design is SET TO SET only — same quantity of every colour. Use SET + / − above.')));
  }

  void _tap(double x, double y, List<List<int>>? boxes) {
    if (_setOnly) {
      _setOnlyNote();
      return;
    }
    final marks = [..._s.marks];
    // A tap on a number placed by hand (no box) adds to THAT number.
    final free = _markAt(x, y, 0.08);
    if (free != null && marks[free].box == null) {
      marks[free] = _crossMode
          ? marks[free].withN(marks[free].n < 0 ? 1 : -1)
          : marks[free].withN(marks[free].n < 0 ? 1 : marks[free].n + 1);
      _push(_s.copy(marks: marks));
      return;
    }
    final box = _hitBox(boxes, x, y);
    if (box != null) {
      final i = marks.indexWhere((m) => m.box == box);
      if (_crossMode) {
        // ✕ toggles: cross this colour / take the cross off again.
        if (i >= 0 && marks[i].n < 0) {
          marks.removeAt(i);
        } else if (i >= 0) {
          marks[i] = marks[i].withN(-1);
        } else {
          final spot = _labelSpot(box, boxes!, _points);
          marks.add(PickMark(spot.dx, spot.dy, -1, box));
        }
      } else if (i >= 0 &&
          math.sqrt(math.pow(marks[i].x - x, 2) + math.pow(marks[i].y - y, 2)) > 0.16 &&
          _markAt(x, y, 0.08) == null) {
        // Owner 12-Oct: tapping a DIFFERENT saree that the photo-reading
        // merged into this one (far from its number) starts its own number.
        marks.add(PickMark(x, y, 1));
      } else if (i >= 0) {
        // A crossed colour tapped normally becomes 1 again.
        marks[i] = marks[i].withN(marks[i].n < 0 ? 1 : marks[i].n + 1);
      } else {
        final spot = _labelSpot(box, boxes!, _points);
        marks.add(PickMark(spot.dx, spot.dy, 1, box));
      }
      _push(_s.copy(marks: marks));
      return;
    }
    if (boxes != null && boxes.isNotEmpty) {
      // Owner: numbers go ONLY on sarees — floor, grass, cards do nothing.
      // (Sets come from the − SET + buttons.)
      final near = _markAt(x, y, 0.06);
      // Owner 12-Oct: a saree the photo-reading missed must still be
      // tappable — a tap inside the area where the sarees lie (not the
      // grass / cards around it) starts a number there.
      final top = boxes.map((b) => b[0]).reduce(math.min) / 1000;
      final left = boxes.map((b) => b[1]).reduce(math.min) / 1000;
      final bottom = boxes.map((b) => b[2]).reduce(math.max) / 1000;
      final right = boxes.map((b) => b[3]).reduce(math.max) / 1000;
      final inside = x >= left && x <= right && y >= top && y <= bottom;
      if (near != null) {
        marks[near] = marks[near].withN(marks[near].n + 1);
        _push(_s.copy(marks: marks));
      } else if (inside) {
        marks.add(PickMark(x, y, _crossMode ? -1 : 1));
        _push(_s.copy(marks: marks));
      } else {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(
              duration: Duration(milliseconds: 1200),
              content: Text(t('Tap on a saree', 'साड़ी पर टैप करें'))));
      }
      return;
    }
    // Layout not known yet: a tap near an existing number adds to it, else
    // starts a new colour. SET comes from the button below.
    final near = _markAt(x, y, 0.08);
    if (_crossMode) {
      if (near != null && marks[near].n < 0) {
        marks.removeAt(near);
      } else if (near != null) {
        marks[near] = marks[near].withN(-1);
      } else {
        marks.add(PickMark(x, y, -1));
      }
    } else if (near != null) {
      marks[near] = marks[near].withN(marks[near].n < 0 ? 1 : marks[near].n + 1);
    } else {
      marks.add(PickMark(x, y, 1));
    }
    _push(_s.copy(marks: marks));
  }

  Future<int?> _askQty(String title, int current) {
    final ctrl = TextEditingController(text: '$current');
    const quick = [0, 1, 2, 3, 4, 5, 6, 8, 10, 12, 15, 20, 25, 30, 50, 100];
    return showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.fromLTRB(
            16, 16, 16, 16 + MediaQuery.of(ctx).viewInsets.bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title, style: Theme.of(ctx).textTheme.titleMedium),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(
                child: TextField(
                  controller: ctrl,
                  autofocus: false,
                  keyboardType: TextInputType.number,
                  inputFormatters: [
                    FilteringTextInputFormatter.digitsOnly,
                    LengthLimitingTextInputFormatter(4)
                  ],
                  decoration: InputDecoration(
                      labelText: t('Type quantity', 'संख्या लिखें'),
                      border: OutlineInputBorder(),
                      isDense: true),
                  onSubmitted: (v) => Navigator.pop(ctx, int.tryParse(v)),
                ),
              ),
              const SizedBox(width: 10),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, int.tryParse(ctrl.text)),
                child: const Text('OK'),
              ),
            ]),
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final q in quick)
                  ChoiceChip(
                    label: Text(q == 0 ? t('Remove', 'हटाएँ') : '$q'),
                    selected: q == current,
                    onSelected: (_) => Navigator.pop(ctx, q),
                  ),
              ],
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<void> _editMark(int i) async {
    final v = await _askQty(t('Pieces of this colour', 'इस रंग के पीस'), _s.marks[i].n);
    if (v == null || !mounted) return;
    final marks = [..._s.marks];
    if (v <= 0) {
      marks.removeAt(i);
    } else {
      marks[i] = marks[i].withN(v);
    }
    _push(_s.copy(marks: marks));
  }

  /// Sarees found on the current photo (set in build).
  List<List<int>>? _boxesNow;

  int get _setsShown => _s.sets > 0 ? _s.sets : _s.shown;

  /// Owner 12-Oct: SET puts the number on EVERY saree — 1 SET → 1 on each,
  /// 2 SET → 2 on each. The customer can then tap a saree for more, or hold
  /// its number to change it (0 removes that colour).
  void _setTo(int target) {
    target = math.max(0, target);
    final boxes = _boxesNow;
    if (boxes == null || boxes.isEmpty || _s.sets > 0) {
      _push(_s.copy(sets: target)); // layout unknown / old cart item
      return;
    }
    final delta = target - _s.shown;
    if (delta == 0) return;
    final marks = <PickMark>[];
    for (final m in _s.marks) {
      if (m.n < 0) {
        marks.add(m); // ✕ not wanted stays out of the sets
        continue;
      }
      final n = m.n + delta;
      if (n > 0) marks.add(m.withN(n));
    }
    if (delta > 0) {
      for (var b = 0; b < boxes.length; b++) {
        if (_s.marks.any((m) => m.box == b)) continue;
        final spot = _labelSpot(b, boxes, _points);
        marks.add(PickMark(spot.dx, spot.dy, delta, b));
      }
    }
    _push(_s.copy(marks: marks, shown: target));
  }

  Future<void> _editSets() async {
    final v = await _askQty(t('Sets (1 set = one of every colour)', 'सेट (1 सेट = हर रंग का एक पीस)'), _setsShown);
    if (v == null || !mounted) return;
    _setTo(v);
  }

  /// Undo: the recorded history first; when the design was reopened (no
  /// history), step back from the last selection — last number −1, then the
  /// sets — until the photo is clear (owner).
  void _undoLast() {
    if (_undo.isNotEmpty) {
      setState(() => _s = _undo.removeLast());
      return;
    }
    final marks = [..._s.marks];
    final i = marks.lastIndexWhere((m) => m.n > 0);
    if (i >= 0) {
      final n = marks[i].n - 1;
      if (n <= 0) {
        marks.removeAt(i);
      } else {
        marks[i] = marks[i].withN(n);
      }
      setState(() => _s = _s.copy(marks: marks));
    } else if (_s.sets > 0) {
      setState(() => _s = _s.copy(sets: _s.sets - 1));
    } else if (_s.shown > 0) {
      setState(() => _s = _s.copy(shown: _s.shown - 1));
    }
  }

  Future<void> _done({bool leaving = false}) async {
    final favs = ref.read(favoritesProvider);
    if (_s.isEmpty) {
      // Owner 11-Oct: nothing selected (no piece, no SET) = it can't be in the cart.
      if (!leaving) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Select at least 1 piece (tap a saree) or 1 SET to add this design.')));
        return;
      }
      if (favs.contains(widget.photoId)) {
        await ref.read(favoritesProvider.notifier).toggle(widget.photoId); // also clears its pick
      }
      if (mounted) context.pop();
      return;
    }
    // SET TO SET only (below ₹310): every colour exactly the SET number.
    if (_setOnly && _s.shown > 0 && _s.marks.any((m) => m.n != _s.shown)) {
      _s = _s.copy(marks: [for (final m in _s.marks) if (m.n != 0) m.withN(_s.shown)]);
    }
    await ref.read(picksProvider.notifier).set(widget.photoId, _s);
    // Picking something puts the design in the cart.
    if (!favs.contains(widget.photoId)) {
      await ref.read(favoritesProvider.notifier).toggle(widget.photoId);
    }
    if (mounted) context.pop();
  }

  @override
  Widget build(BuildContext context) {
    final photo = _photo;
    ref.watch(piecesProvider);
    final pc = ref.read(piecesProvider.notifier);
    if (photo == null) {
      return Scaffold(
          appBar: AppBar(),
          body: const Center(child: UText('Photo not found.')));
    }
    final boxes = pc.boxesFor(photo);
    _boxesNow = boxes;
    _points = pc.pointsFor(photo);
    final count = pc.piecesFor(photo);
    // Instant: the grid thumbnail is already on the phone — show it at once
    // and let the sharp copy (the same one the full-photo view uses, so
    // usually cached too) fade in on top. No spinner.
    final low = CachedNetworkImageProvider(photo.thumbUrl(),
        cacheManager: photoCacheManager);
    final img = CachedNetworkImageProvider(photo.detailUrl(),
        cacheManager: photoCacheManager);
    _resolveAspect(low);
    _resolveAspect(img);
    final total = _s.total(count);

    return PopScope(
      canPop: _undo.isEmpty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        await _done(leaving: true); // leaving with changes = keep them (empty = not in cart)
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
          // Owner: no design number up here — two boxed buttons with icons,
          // spread across with space between (11-Oct).
          titleSpacing: 0,
          title: Row(children: [
            Expanded(
              child: BarButton(
                dark: true,
                icon: Icons.undo_rounded,
                label: 'UNDO LAST ACTION',
                onTap: (_undo.isEmpty && _s.isEmpty) ? null : _undoLast,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: BarButton(
                dark: true,
                icon: Icons.delete_outline_rounded,
                label: 'CLEAR ALL',
                color: const Color(0xFFFF8A80),
                onTap: _s.isEmpty ? null : () => _push(const PickState()),
              ),
            ),
          ]),
          actions: const [SizedBox(width: 12)],
        ),
        body: Column(
          children: [
            if (_setOnly)
              Container(
                width: double.infinity,
                color: const Color(0xFF1B8E3A),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                child: const Text('SET TO SET ONLY — designs below ₹310 are sold in full sets',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 13)),
              ),
            if (!_s.isEmpty)
              Container(
                width: double.infinity,
                color: const Color(0xFF111111),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 16),
                child: Text(
                  _s.summary(count),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      color: Colors.white, fontWeight: FontWeight.w900, fontSize: 21, height: 1.25),
                ),
              ),
            // SET − / + and ✕ right under the summary (owner, 11-Oct-2026).
            Container(
              width: double.infinity,
              color: const Color(0xFF1B1A18),
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                // SET: − / + so a wrong tap is easy to take back; tap the
                // number to type any amount.
                Container(
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.white54),
                    borderRadius: BorderRadius.circular(24),
                  ),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    IconButton(
                      tooltip: t('One set less', 'एक सेट कम'),
                      visualDensity: VisualDensity.compact,
                      color: Colors.white,
                      disabledColor: Colors.white24,
                      icon: const Icon(Icons.remove_rounded),
                      onPressed: _setsShown > 0 ? () => _setTo(_setsShown - 1) : null,
                    ),
                    InkWell(
                      onTap: _editSets,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Text('$_setsShown SET',
                            style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w800)),
                      ),
                    ),
                    IconButton(
                      tooltip: t('One set more', 'एक सेट ज़्यादा'),
                      visualDensity: VisualDensity.compact,
                      color: Colors.white,
                      icon: const Icon(Icons.add_rounded),
                      onPressed: () => _setTo(_setsShown + 1),
                    ),
                  ]),
                ),
                ],
              ),
            ),
            Expanded(
              child: Center(
                child: _aspect == null
                    ? const SizedBox.shrink()
                    : AspectRatio(
                        aspectRatio: _aspect!,
                        child: LayoutBuilder(builder: (context, c) {
                          final w = c.maxWidth, h = c.maxHeight;
                          final r = math.min(w, h) * 0.06;
                          return GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTapUp: (d) => _tap(d.localPosition.dx / w,
                                d.localPosition.dy / h, boxes),
                            onLongPressStart: (d) {
                              if (_setOnly) {
                                _setOnlyNote();
                                return;
                              }
                              final i = _markAt(d.localPosition.dx / w,
                                  d.localPosition.dy / h, 0.08);
                              if (i != null) {
                                _editMark(i);
                              }
                            },
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                Image(image: low, fit: BoxFit.fill, gaplessPlayback: true),
                                Image(
                                  image: img,
                                  fit: BoxFit.fill,
                                  gaplessPlayback: true,
                                  frameBuilder: (_, child, frame, sync) =>
                                      sync || frame != null
                                          ? AnimatedOpacity(
                                              opacity: frame == null ? 0 : 1,
                                              duration: const Duration(milliseconds: 180),
                                              child: child)
                                          : const SizedBox.shrink(),
                                ),
                                for (final m in _s.marks)
                                  if (m.n != 0)
                                    Positioned(
                                      left: m.x * w - r,
                                      top: m.y * h - r,
                                      width: r * 2,
                                      height: r * 2,
                                      child: IgnorePointer(
                                        child: Container(
                                          alignment: Alignment.center,
                                          decoration: BoxDecoration(
                                            color: m.n < 0
                                                ? const Color(0xFFD32F2F)
                                                : const Color(0xFF1B8E3A),
                                            shape: BoxShape.circle,
                                            border: Border.all(
                                                color: Colors.white, width: 2),
                                            boxShadow: const [
                                              BoxShadow(
                                                  color: Colors.black54,
                                                  blurRadius: 4)
                                            ],
                                          ),
                                          child: Text(m.n < 0 ? '✕' : '${m.n}',
                                              style: TextStyle(
                                                  color: Colors.white,
                                                  fontWeight: FontWeight.w900,
                                                  fontSize: r * 0.95)),
                                        ),
                                      ),
                                    ),
                              ],
                            ),
                          );
                        }),
                      ),
              ),
            ),
          ],
        ),
        bottomNavigationBar: Material(
          color: const Color(0xFF1B1A18),
          child: SafeArea(
            top: false,
            minimum: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            child: Row(
              children: [
                Expanded(
                  // Owner: the total is already at the top — show the design no.
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'DESIGN NO. - ${(photo.designNumber ?? '-').toUpperCase()}',
                      style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w900,
                          fontSize: 24,
                          letterSpacing: 0.5),
                    ),
                  ),
                ),
                FilledButton(
                  style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF1B8E3A)),
                  onPressed: _done,
                  child: Text(t('DONE', 'हो गया')),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
