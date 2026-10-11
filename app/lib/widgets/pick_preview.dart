import 'dart:typed_data';

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

class _PickPreviewImageState extends State<PickPreviewImage> {
  static final Map<String, Uint8List> _cache = {};
  Uint8List? _bytes;

  String get _key =>
      '${widget.photo.id}|${widget.pick.toJson()}|${widget.sareeCount}|${widget.band}';

  @override
  void initState() {
    super.initState();
    _render();
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
      return Container(color: const Color(0xFFF1EEE8));
    }
    return Image.memory(b,
        fit: BoxFit.cover, gaplessPlayback: true, cacheWidth: widget.decodeWidth);
  }
}
