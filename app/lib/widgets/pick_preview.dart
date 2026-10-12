import 'dart:typed_data';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../models/photo.dart';
import '../services/photo_freshness.dart';
import '../services/picks_service.dart';

/// The cart tile shows the design exactly as it will reach the shop: the
/// photo with the customer's green numbers + "N SET" drawn on it.
class PickPreviewImage extends StatefulWidget {
  final Photo photo;
  final PickState pick;
  final int? decodeWidth;
  final int? sareeCount;

  /// Draw the summary band above the photo (Telegram); tiles show it as text.
  final bool band;
  const PickPreviewImage(
      {super.key,
      required this.photo,
      required this.pick,
      this.decodeWidth,
      this.sareeCount,
      this.band = true});

  @override
  State<PickPreviewImage> createState() => _PickPreviewImageState();
}

/// Draws a design with its picks ahead of time (pick screen DONE), so the
/// tile shows the right numbers the moment the grid comes back (owner 12-Oct).
Future<void> warmPickPreview(Photo photo, PickState pick, {int? sareeCount}) =>
    _PickPreviewImageState.render(photo, pick, sareeCount, false);

class _PickPreviewImageState extends State<PickPreviewImage> {
  static final Map<String, Uint8List> _cache = {};

  static String keyOf(Photo p, PickState pick, int? count, bool band) =>
      '${p.id}|${pick.toJson()}|$count|$band';

  static Future<Uint8List?> render(Photo photo, PickState pick, int? count, bool band) async {
    final key = keyOf(photo, pick, count, band);
    final hit = _cache[key];
    if (hit != null) return hit;
    try {
      final file = await photoCacheManager.getSingleFile(photo.thumbUrl(width: 800));
      final out = await renderPicks(await file.readAsBytes(), pick, sareeCount: count, band: band);
      if (_cache.length > 60) _cache.clear();
      _cache[key] = out;
      return out;
    } catch (_) {
      return null;
    }
  }
  Uint8List? _bytes;

  String get _key => keyOf(widget.photo, widget.pick, widget.sareeCount, widget.band);

  @override
  void initState() {
    _bytes = _cache[_key]; // drawn already (DONE warms it) → no blank frame
    super.initState();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_bytes == null) _render();
  }

  @override
  void didUpdateWidget(covariant PickPreviewImage old) {
    super.didUpdateWidget(old);
    if (old.pick.toJson().toString() != widget.pick.toJson().toString() ||
        old.photo.id != widget.photo.id) {
      _render();
    }
  }

  Future<void> _render() async {
    final key = _key;
    final hit = _cache[key];
    if (hit != null) {
      setState(() => _bytes = hit);
      return;
    }
    try {
      final file = await photoCacheManager.getSingleFile(widget.photo.thumbUrl(width: 800));
      final out = await renderPicks(await file.readAsBytes(), widget.pick,
          sareeCount: widget.sareeCount, band: widget.band);
      if (_cache.length > 60) _cache.clear();
      _cache[key] = out;
      if (mounted && key == _key) setState(() => _bytes = out);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final b = _bytes;
    if (b == null) {
      // Never a blank tile: the plain photo until the numbers are drawn.
      return CachedNetworkImage(
          imageUrl: widget.photo.thumbUrl(),
          cacheManager: photoCacheManager,
          fit: BoxFit.cover,
          errorWidget: (_, __, ___) => Container(color: const Color(0xFFF1EEE8)));
    }
    return Image.memory(b,
        fit: BoxFit.cover, gaplessPlayback: true, cacheWidth: widget.decodeWidth);
  }
}
