import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../providers/providers.dart';

/// TAP-TO-SELECT (owner, 11-Oct-2026). On a design photo the customer taps:
///   • a saree      → +1 of that colour (1, 2, 3 …); untapped colours = not wanted
///   • the background → +1 SET (one piece of EVERY colour)
///   • long-press a number → type / pick any quantity (0 removes it)
/// Every order then arrives in the same clean format: numbered circles on the
/// colours and an "N SET" label.
class PickMark {
  final double x, y; // 0..1 of the image
  final int n;
  final int? box; // index of the detected saree, when known
  const PickMark(this.x, this.y, this.n, [this.box]);

  PickMark withN(int v) => PickMark(x, y, v, box);
  Map<String, dynamic> toJson() => {'x': x, 'y': y, 'n': n, if (box != null) 'b': box};
  factory PickMark.fromJson(Map<String, dynamic> j) => PickMark(
      (j['x'] as num).toDouble(), (j['y'] as num).toDouble(), j['n'] as int, j['b'] as int?);
}

class PickState {
  final int sets;
  final List<PickMark> marks;

  /// Owner 12-Oct: "1 SET" now puts a 1 on EVERY saree (2 SET → 2 on each).
  /// The pieces live in [marks]; [shown] only remembers how many SETs the
  /// customer pressed, for the "2 SET (12 PCS) + 5 …" wording.
  final int shown;
  const PickState({this.sets = 0, this.marks = const [], this.shown = 0});

  /// Pieces that belong to the pressed SETs (each colour counts up to [shown]).
  int get _setPcs => shown <= 0
      ? 0
      : marks.fold(0, (s, m) => s + (m.n > 0 ? math.min(m.n, shown) : 0));

  bool get isEmpty => sets == 0 && marks.every((m) => m.n <= 0);
  int get markPieces => marks.fold(0, (s, m) => s + (m.n > 0 ? m.n : 0));

  /// Colours crossed out (✕) — left out of every SET.
  int get crossed => marks.where((m) => m.n < 0).length;

  int _perSet(int count) => math.max(0, count - crossed);

  /// Total pieces; null when sets are chosen but the photo's saree count
  /// isn't known yet.
  int? total(int? sareeCount) {
    if (sets > 0 && sareeCount == null) return null;
    return sets * _perSet(sareeCount ?? 0) + markPieces;
  }

  /// Pieces to count for the ₹30,000 check. Sets are NEVER dropped: when the
  /// photo's saree count isn't known yet, a set counts as at least 1 piece.
  int minTotal(int? sareeCount) =>
      sets * (sareeCount == null ? 1 : _perSet(sareeCount)) + markPieces;

  /// Exact only when there are no sets, or the saree count is known.
  bool exact(int? sareeCount) => sets == 0 || sareeCount != null;

  /// "2 SET (12) + 8 SELECTED = 20 SAREES" — the clear summary drawn on the
  /// photo (owner, 11-Oct-2026).
  String summary(int? sareeCount) {
    if (sets == 0 && shown > 0) {
      final extra = markPieces - _setPcs;
      return '$shown SET ($_setPcs PCS)${extra > 0 ? ' + $extra EXTRA ${extra == 1 ? 'PC' : 'PCS'}' : ''} = $markPieces ${markPieces == 1 ? 'SAREE' : 'SAREES'}';
    }
    final parts = <String>[
      if (sets > 0)
        sareeCount != null
            ? '$sets SET (${sets * _perSet(sareeCount)} PCS)'
            : '$sets SET',
      if (markPieces > 0) '$markPieces SELECTED ${markPieces == 1 ? 'PC' : 'PCS'}',
    ];
    final tot = total(sareeCount);
    final x = crossed > 0 ? '  ·  $crossed ✕ NOT WANTED' : '';
    return tot == null
        ? '${parts.join(' + ')}$x'
        : '${parts.join(' + ')} = $tot ${tot == 1 ? 'SAREE' : 'SAREES'}$x';
  }

  String label(int? sareeCount) {
    if (sets == 0 && shown > 0) {
      final extra = markPieces - _setPcs;
      return '$shown SET${extra > 0 ? ' + $extra ${extra == 1 ? 'pc' : 'pcs'}' : ''} = $markPieces ${markPieces == 1 ? 'pc' : 'pcs'}';
    }
    final parts = <String>[
      if (sets > 0) '$sets SET',
      if (markPieces > 0) '$markPieces ${markPieces == 1 ? 'pc' : 'pcs'}',
    ];
    final t = total(sareeCount);
    final head = parts.join(' + ');
    return (sets > 0 && t != null) ? '$head = $t ${t == 1 ? 'pc' : 'pcs'}' : head;
  }

  PickState copy({int? sets, List<PickMark>? marks, int? shown}) =>
      PickState(sets: sets ?? this.sets, marks: marks ?? this.marks, shown: shown ?? this.shown);

  Map<String, dynamic> toJson() =>
      {'s': sets, 'm': marks.map((e) => e.toJson()).toList(), if (shown > 0) 'ss': shown};
  factory PickState.fromJson(Map<String, dynamic> j) => PickState(
        sets: (j['s'] ?? 0) as int,
        shown: (j['ss'] ?? 0) as int,
        marks: ((j['m'] ?? const []) as List)
            .map((e) => PickMark.fromJson(Map<String, dynamic>.from(e)))
            .toList(),
      );
}

/// Owner 12-Oct: designs below ₹310 are sold SET TO SET only — no picking
/// or leaving out colours.
const int kSetOnlyBelow = 310;
bool isSetOnly(int? price) => price != null && price > 0 && price < kSetOnlyBelow;

class PicksNotifier extends StateNotifier<Map<String, PickState>> {
  PicksNotifier(this._prefs) : super(_load(_prefs));
  final SharedPreferences _prefs;
  static const _kKey = 'picks_v1';

  static Map<String, PickState> _load(SharedPreferences p) {
    try {
      final m = jsonDecode(p.getString(_kKey) ?? '{}') as Map<String, dynamic>;
      return m.map((k, v) =>
          MapEntry(k, PickState.fromJson(Map<String, dynamic>.from(v))));
    } catch (_) {
      return {};
    }
  }

  Future<void> set(String photoId, PickState s) async {
    final next = {...state};
    if (s.isEmpty) {
      next.remove(photoId);
    } else {
      next[photoId] = s;
    }
    state = next;
    await _prefs.setString(
        _kKey, jsonEncode(next.map((k, v) => MapEntry(k, v.toJson()))));
  }

  Future<void> remove(String photoId) => set(photoId, const PickState());
}

final picksProvider =
    StateNotifierProvider<PicksNotifier, Map<String, PickState>>(
        (ref) => PicksNotifier(ref.watch(sharedPreferencesProvider)));

/// Draws the customer's picks onto the photo (green numbered circles + an
/// "N SET" banner) so the shop sees exactly what was chosen.
Future<Uint8List> renderPicks(Uint8List bytes, PickState pick,
    {int? sareeCount, bool band = true}) async {
  if (pick.isEmpty) return bytes;
  try {
    final codec = await ui.instantiateImageCodec(bytes);
    final image = (await codec.getNextFrame()).image;
    final w = image.width.toDouble(), h = image.height.toDouble();
    final r = (w < h ? w : h) * 0.055;
    // A dark band ABOVE the photo carries the summary, so it never covers a
    // saree or a number.
    final bandH = band ? (r * 2.2).roundToDouble() : 0.0;
    final rec = ui.PictureRecorder();
    final c = Canvas(rec, Rect.fromLTWH(0, 0, w, h + bandH));
    if (band) {
      c.drawRect(Rect.fromLTWH(0, 0, w, bandH), Paint()..color = const Color(0xFF111111));
      final sp = TextPainter(
      text: TextSpan(
          text: pick.summary(sareeCount),
          style: TextStyle(
              color: Colors.white, fontSize: r * 0.95, fontWeight: FontWeight.w900)),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: w - r);
      sp.paint(c, Offset((w - sp.width) / 2, (bandH - sp.height) / 2));
      c.translate(0, bandH);
    }
    c.drawImage(image, Offset.zero, Paint());
    for (final m in pick.marks) {
      if (m.n == 0) continue;
      final o = Offset(m.x * w, m.y * h);
      if (m.n < 0) {
        c.drawCircle(o, r * 1.08, Paint()..color = Colors.white);
        c.drawCircle(o, r, Paint()..color = const Color(0xFFD32F2F));
        final xp = Paint()
          ..color = Colors.white
          ..strokeWidth = r * 0.22
          ..strokeCap = StrokeCap.round;
        final d = r * 0.45;
        c.drawLine(o + Offset(-d, -d), o + Offset(d, d), xp);
        c.drawLine(o + Offset(d, -d), o + Offset(-d, d), xp);
        continue;
      }
      c.drawCircle(o, r * 1.08, Paint()..color = Colors.white);
      c.drawCircle(o, r, Paint()..color = const Color(0xFF1B8E3A));
      final tp = TextPainter(
        text: TextSpan(
            text: '${m.n}',
            style: TextStyle(
                color: Colors.white, fontSize: r * 1.15, fontWeight: FontWeight.w900)),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(c, o - Offset(tp.width / 2, tp.height / 2));
    }
    if (false) {
      final tp = TextPainter(
        text: TextSpan(
            text: ' ${pick.sets} SET ',
            style: TextStyle(
                color: Colors.white, fontSize: r * 1.1, fontWeight: FontWeight.w900)),
        textDirection: TextDirection.ltr,
      )..layout();
      final box = Rect.fromLTWH(r * 0.5, r * 0.5, tp.width + r * 0.6, tp.height + r * 0.4);
      c.drawRRect(RRect.fromRectAndRadius(box, Radius.circular(r * 0.4)),
          Paint()..color = const Color(0xE61B1A18));
      tp.paint(c, box.topLeft + Offset(r * 0.3, r * 0.2));
    }
    final out = await rec.endRecording().toImage(image.width, image.height + bandH.toInt());
    final png = await out.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    out.dispose();
    if (png == null) return bytes;
    final jpg = await FlutterImageCompress.compressWithList(
        png.buffer.asUint8List(), quality: 88, format: CompressFormat.jpeg);
    return jpg.isNotEmpty ? jpg : png.buffer.asUint8List();
  } catch (_) {
    return bytes;
  }
}
