import 'package:catalog_app/widgets/caps_text.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/photo.dart';
import '../providers/providers.dart';
import '../services/photo_freshness.dart';
import '../services/price_check.dart';

/// Lets the customer type a custom price for each photo in the cart before
/// sharing. Pops with a `{photoId: price}` map for every photo a price was
/// typed into (photos left blank keep their original printed price), or `null`
/// if the user backs out.
class ManualPriceScreen extends ConsumerStatefulWidget {
  final List<Photo> photos;
  const ManualPriceScreen({super.key, required this.photos});

  @override
  ConsumerState<ManualPriceScreen> createState() => _ManualPriceScreenState();
}

class _ManualPriceScreenState extends ConsumerState<ManualPriceScreen> {
  late final Map<String, TextEditingController> _ctrls;
  final TextEditingController _bulkCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _ctrls = {for (final p in widget.photos) p.id: TextEditingController()};
  }

  @override
  void dispose() {
    for (final c in _ctrls.values) {
      c.dispose();
    }
    _bulkCtrl.dispose();
    super.dispose();
  }

  /// Fill every photo's price box with the value typed in the "set all" field
  /// (wholesale: price everything the same, then tweak the few exceptions).
  void _applyToAll() {
    final v = _bulkCtrl.text.trim();
    if (v.isEmpty) return;
    FocusScope.of(context).unfocus(); // drop the keypad after applying
    setState(() {
      for (final c in _ctrls.values) {
        c.text = v;
      }
    });
  }

  /// Full-screen, pinch-zoomable preview of a photo (tap it or the ✕ to close).
  void _expand(Photo p) {
    FocusScope.of(context).unfocus(); // drop the keypad first
    showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.92),
      builder: (ctx) => Stack(
        children: [
          GestureDetector(
            onTap: () => Navigator.of(ctx).pop(),
            child: InteractiveViewer(
              minScale: 1,
              maxScale: 5,
              child: Center(
                child: PhotoImageRefresh(
                  child: CachedNetworkImage(
                    imageUrl: p.detailUrl(),
                    cacheManager: photoCacheManager,
                    fit: BoxFit.contain,
                    placeholder: (_, __) => const Center(
                      child: CircularProgressIndicator(color: Colors.white),
                    ),
                    errorWidget: (_, __, ___) => const Center(
                      child: Icon(Icons.broken_image_outlined,
                          color: Colors.white, size: 48),
                    ),
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            top: 44,
            right: 12,
            child: IconButton(
              icon: const Icon(Icons.close, color: Colors.white, size: 28),
              onPressed: () => Navigator.of(ctx).pop(),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 36,
            child: UText(
              p.designNumber ?? p.filename,
              textAlign: TextAlign.center,
              style: const TextStyle(
                  color: Colors.white, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }

  void _send() {
    final out = <String, int>{};
    _ctrls.forEach((id, c) {
      final v = int.tryParse(c.text.trim());
      if (v != null && v > 0) out[id] = v;
    });
    Navigator.of(context).pop(out);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: UText('Set prices · ${widget.photos.length}'),
        actions: [
          TextButton(
            onPressed: _send,
            child: const UText('SEND',
                style:
                    TextStyle(fontWeight: FontWeight.w800, letterSpacing: 0.5)),
          ),
        ],
      ),
      // The number pad has no Return key, so tapping any blank area dismisses
      // it, and SEND lives in the top bar so it's always reachable.
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => FocusScope.of(context).unfocus(),
        child: Column(
          children: [
            Container(
              width: double.infinity,
              color: scheme.surfaceContainerHighest,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: UText(
                'Type the price you want printed on each photo. '
                'Leave blank to keep the original.',
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _bulkCtrl,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      decoration: const InputDecoration(
                        isDense: true,
                        prefixText: '₹ ',
                        labelText: 'Set all to',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.tonal(
                    onPressed: _applyToAll,
                    child: const UText('Apply to all'),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView.separated(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
                itemCount: widget.photos.length,
                separatorBuilder: (_, __) => const Divider(height: 20),
                itemBuilder: (context, i) {
                  final p = widget.photos[i];
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      GestureDetector(
                        onTap: () => _expand(p),
                        child: Stack(
                          alignment: Alignment.bottomRight,
                          children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: PhotoImageRefresh(
                                child: CachedNetworkImage(
                                  imageUrl: p.thumbUrl(),
                                  cacheManager: photoCacheManager,
                                  memCacheWidth: 168,
                                  width: 56,
                                  height: 72,
                                  fit: BoxFit.cover,
                                  placeholder: (_, __) => Container(
                                    width: 56,
                                    height: 72,
                                    color: scheme.surfaceContainerHighest,
                                  ),
                                  errorWidget: (_, __, ___) => Container(
                                    width: 56,
                                    height: 72,
                                    color: scheme.surfaceContainerHighest,
                                    child: const Icon(
                                        Icons.broken_image_outlined,
                                        size: 18),
                                  ),
                                ),
                              ),
                            ),
                            Container(
                              margin: const EdgeInsets.all(2),
                              padding: const EdgeInsets.all(1),
                              decoration: const BoxDecoration(
                                color: Colors.black54,
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(Icons.zoom_in,
                                  size: 13, color: Colors.white),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            UText(
                              p.designNumber ?? p.filename,
                              style:
                                  const TextStyle(fontWeight: FontWeight.w700),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 3),
                            Builder(builder: (context) {
                              final check = ref.watch(priceCheckProvider);
                              final curPhotos = ref.watch(photosProvider);
                              final cur = curPhotos.cast<Photo?>().firstWhere(
                                  (x) => x!.id == p.id,
                                  orElse: () => p) ?? p;
                              final d = priceDisplayFor(cur, check);
                              final shown = d == PriceDisplay.show ? cur.price : null;
                              return UText(
                                shown != null
                                    ? 'Current: Rs $shown/-'
                                    : d == PriceDisplay.none
                                        ? 'No price detected'
                                        : 'Checking price…',
                                style: TextStyle(
                                    fontSize: 12, color: scheme.onSurfaceVariant),
                              );
                            }),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      SizedBox(
                        width: 104,
                        child: TextField(
                          controller: _ctrls[p.id],
                          keyboardType: TextInputType.number,
                          inputFormatters: [
                            FilteringTextInputFormatter.digitsOnly
                          ],
                          textAlign: TextAlign.center,
                          decoration: InputDecoration(
                            isDense: true,
                            prefixText: '₹ ',
                            hintText: p.price?.toString() ?? 'price',
                            border: const OutlineInputBorder(),
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: Material(
        elevation: 8,
        color: scheme.surface,
        child: SafeArea(
          top: false,
          minimum: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: SizedBox(
            width: double.infinity,
            height: 52,
            child: FilledButton.icon(
              onPressed: _send,
              icon: const Icon(Icons.send_rounded),
              label: const UText('SEND',
                  style: TextStyle(
                      fontWeight: FontWeight.w700, letterSpacing: 0.5)),
            ),
          ),
        ),
      ),
    );
  }
}
