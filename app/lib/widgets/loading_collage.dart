import 'package:catalog_app/widgets/caps_text.dart';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config.dart';
import '../providers/providers.dart';
import '../services/drive_scraper.dart';
import '../services/drive_urls.dart';
import '../services/photo_freshness.dart';

/// Full-screen "saree fashion" loading collage shown only on the very first
/// app launch. Live photos discovered by the Drive scrape pop into random
/// positions, drift gently in a sine-wave float, and respond to taps & drags
/// (cards push away from the touch point with spring physics).
class LoadingCollage extends ConsumerStatefulWidget {
  const LoadingCollage({super.key});

  @override
  ConsumerState<LoadingCollage> createState() => _LoadingCollageState();
}

class _LoadingCollageState extends ConsumerState<LoadingCollage>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ticker;
  final math.Random _rng = math.Random(7);
  final List<_Slot> _slots = [];
  static const int _maxCards = 12; // 12-Oct: lighter first load (iPhone memory)
  Size _canvas = Size.zero;

  @override
  void initState() {
    super.initState();
    _ticker = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 60),
    )..repeat();
    _ticker.addListener(_step);
    _seedSlots();
  }

  void _seedSlots() {
    for (int i = 0; i < _maxCards; i++) {
      _slots.add(_Slot(
        baseX: _rng.nextDouble(),
        baseY: _rng.nextDouble(),
        rotation: (_rng.nextDouble() - 0.5) * 0.45,
        scale: 0.65 + _rng.nextDouble() * 0.4,
        phase: _rng.nextDouble() * math.pi * 2,
        cardWidth: 110 + _rng.nextDouble() * 50,
      ));
    }
  }

  void _step() {
    if (!mounted) return;
    // Spring-back + damping for tap/drag velocity.
    for (final s in _slots) {
      s.velocity = Offset(s.velocity.dx * 0.88, s.velocity.dy * 0.88);
      s.displacement = Offset(
        s.displacement.dx * 0.93 + s.velocity.dx,
        s.displacement.dy * 0.93 + s.velocity.dy,
      );
    }
    setState(() {});
  }

  void _pushFromPoint(Offset point) {
    if (_canvas == Size.zero) return;
    for (final s in _slots) {
      final base = Offset(s.baseX * _canvas.width, s.baseY * _canvas.height);
      final current = base + s.displacement;
      final delta = current - point;
      final dist = delta.distance;
      if (dist < 1) continue;
      const reach = 220.0;
      if (dist >= reach) continue;
      final strength = (1 - dist / reach) * 38;
      s.velocity += Offset(
        delta.dx / dist * strength,
        delta.dy / dist * strength,
      );
    }
  }

  @override
  void dispose() {
    _ticker.removeListener(_step);
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final discovered = ref.watch(discoveredPhotosProvider);
    final progress = ref.watch(scrapeProgressProvider);
    final totals = ref.watch(lastKnownTotalsProvider);

    // Three-phase percentage:
    //   Scanning   (Drive walk)         : 0    .. 0.40
    //   Preparing  (folder cover fetch) : 0.40 .. 0.55
    //   Pricing    (per-photo OCR)      : 0.55 .. 1.00
    double? pct;
    if (progress.phase == ScrapePhase.pricing) {
      if (progress.ocrTotal > 0) {
        final p = progress.ocrReady / progress.ocrTotal;
        pct = (0.55 + p * 0.45).clamp(0.0, 0.99);
      } else {
        pct = 0.99;
      }
    } else if (progress.phase == ScrapePhase.preparing) {
      if (progress.coversTotal > 0) {
        final p = progress.coversReady / progress.coversTotal;
        pct = (0.40 + p * 0.15).clamp(0.0, 0.55);
      } else {
        pct = 0.55;
      }
    } else if (totals.folders > 0 && progress.foldersDone > 0) {
      pct = (progress.foldersDone / totals.folders * 0.40).clamp(0.0, 0.40);
    }

    return LayoutBuilder(builder: (context, constraints) {
      _canvas = Size(constraints.maxWidth, constraints.maxHeight);
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (d) => _pushFromPoint(d.localPosition),
        onPanUpdate: (d) => _pushFromPoint(d.localPosition),
        child: Stack(
          fit: StackFit.expand,
          children: [
            const _SilkBackground(),
            // Discovered photo cards (animated collage).
            ..._buildCards(discovered),
            // Soft vignette so the centre panel reads cleanly.
            IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: Alignment.center,
                    radius: 0.9,
                    colors: [
                      Colors.white.withValues(alpha: 0.0),
                      Colors.white.withValues(alpha: 0.55),
                    ],
                    stops: const [0.4, 1.0],
                  ),
                ),
              ),
            ),
            Center(
              child: _GlassPanel(
                pct: pct,
                folders: progress.foldersDone,
                photos: progress.photosFound,
                phase: progress.phase,
                coversReady: progress.coversReady,
                coversTotal: progress.coversTotal,
                ocrReady: progress.ocrReady,
                ocrTotal: progress.ocrTotal,
              ),
            ),
            // Decorative footer hint
            Positioned(
              left: 0,
              right: 0,
              bottom: 24,
              child: Center(
                child: UText(
                  'TAP OR DRAG THE SCREEN ✨',
                  style: TextStyle(
                    color: const Color(0xFF7A4F5C).withValues(alpha: 0.55),
                    fontSize: 11,
                    letterSpacing: 1.4,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    });
  }

  List<Widget> _buildCards(List<DrivePhoto> discovered) {
    final n = math.min(discovered.length, _slots.length);
    final cards = <Widget>[];
    for (int i = 0; i < n; i++) {
      final slot = _slots[i];
      final photo = discovered[i];
      final t = _ticker.value * 2 * math.pi + slot.phase;
      final driftX = math.cos(t) * 14;
      final driftY = math.sin(t * 0.7) * 18;
      final cardW = slot.cardWidth;
      final cardH = cardW * 1.35;
      final left = slot.baseX * _canvas.width -
          cardW / 2 +
          driftX +
          slot.displacement.dx;
      final top = slot.baseY * _canvas.height -
          cardH / 2 +
          driftY +
          slot.displacement.dy;
      cards.add(Positioned(
        left: left,
        top: top,
        width: cardW,
        height: cardH,
        child: IgnorePointer(
          child: _PhotoCard(
            photoId: photo.id,
            rotation: slot.rotation,
            scale: slot.scale,
          ),
        ),
      ));
    }
    return cards;
  }
}

class _Slot {
  final double baseX; // 0..1 of screen width
  final double baseY; // 0..1 of screen height
  final double rotation; // radians
  final double scale;
  final double phase;
  final double cardWidth;
  Offset displacement = Offset.zero;
  Offset velocity = Offset.zero;
  _Slot({
    required this.baseX,
    required this.baseY,
    required this.rotation,
    required this.scale,
    required this.phase,
    required this.cardWidth,
  });
}

class _PhotoCard extends StatelessWidget {
  final String photoId;
  final double rotation;
  final double scale;
  const _PhotoCard({
    required this.photoId,
    required this.rotation,
    required this.scale,
  });

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 700),
      curve: Curves.easeOutBack,
      builder: (context, t, child) => Opacity(
        opacity: t.clamp(0.0, 1.0),
        child: Transform.scale(
          scale: scale * (0.5 + 0.5 * t),
          child: Transform.rotate(angle: rotation, child: child),
        ),
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          color: Colors.white,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.18),
              blurRadius: 14,
              offset: const Offset(0, 6),
            ),
            BoxShadow(
              color: const Color(0xFFE91E63).withValues(alpha: 0.05),
              blurRadius: 24,
              spreadRadius: 1,
            ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(7),
            child: CachedNetworkImage(
              imageUrl: DriveUrls.thumbnail(photoId, width: kThumbnailWidth),
              cacheManager: photoCacheManager,
              memCacheWidth: 320,
              fit: BoxFit.cover,
              fadeInDuration: const Duration(milliseconds: 200),
              placeholder: (_, __) =>
                  const ColoredBox(color: Color(0xFFF7E9EE)),
              errorWidget: (_, __, ___) =>
                  const ColoredBox(color: Color(0xFFF7E9EE)),
            ),
          ),
        ),
      ),
    );
  }
}

class _SilkBackground extends StatelessWidget {
  const _SilkBackground();

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Color(0xFFFCE4EC), // pale rose
                Color(0xFFFFF3E0), // warm cream
                Color(0xFFFFEBEE), // blush
              ],
              stops: [0.0, 0.55, 1.0],
            ),
          ),
        ),
        // Soft golden glow top-right
        Positioned(
          top: -100,
          right: -80,
          child: Container(
            width: 320,
            height: 320,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [Color(0x55FFD180), Color(0x00FFD180)],
              ),
            ),
          ),
        ),
        // Soft rose glow bottom-left
        Positioned(
          bottom: -120,
          left: -80,
          child: Container(
            width: 320,
            height: 320,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [Color(0x55F8BBD0), Color(0x00F8BBD0)],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _GlassPanel extends StatelessWidget {
  final double? pct;
  final int folders;
  final int photos;
  final ScrapePhase phase;
  final int coversReady;
  final int coversTotal;
  final int ocrReady;
  final int ocrTotal;
  const _GlassPanel({
    required this.pct,
    required this.folders,
    required this.photos,
    required this.phase,
    required this.coversReady,
    required this.coversTotal,
    required this.ocrReady,
    required this.ocrTotal,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final String subtitle;
    if (phase == ScrapePhase.pricing) {
      subtitle = ocrTotal == 0
          ? 'READING PRICES…'
          : 'READING PRICES — $ocrReady / $ocrTotal';
    } else if (phase == ScrapePhase.preparing) {
      subtitle = coversTotal == 0
          ? 'PREPARING DESIGNS…'
          : 'PREPARING DESIGNS — $coversReady / $coversTotal';
    } else if (folders == 0) {
      subtitle = 'CONNECTING…';
    } else {
      subtitle =
          '$folders FOLDER${folders == 1 ? '' : 'S'} • $photos DESIGN${photos == 1 ? '' : 'S'}';
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(28),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: Container(
          constraints: const BoxConstraints(maxWidth: 320),
          padding: const EdgeInsets.fromLTRB(28, 26, 28, 26),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.66),
            borderRadius: BorderRadius.circular(28),
            border: Border.all(
                color: Colors.white.withValues(alpha: 0.55), width: 1.2),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFFB23A48).withValues(alpha: 0.1),
                blurRadius: 30,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 110,
                height: 110,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    SizedBox(
                      width: 110,
                      height: 110,
                      child: CircularProgressIndicator(
                        value: pct,
                        strokeWidth: 5,
                        backgroundColor: const Color(0x33B23A48),
                        color: scheme.primary,
                      ),
                    ),
                    // BB logo lives in the middle of the loading circle.
                    Padding(
                      padding: const EdgeInsets.all(20),
                      child: Image.asset(
                        'assets/icon/bb_logo.png',
                        fit: BoxFit.contain,
                        filterQuality: FilterQuality.medium,
                      ),
                    ),
                  ],
                ),
              ),
              if (pct != null) ...[
                const SizedBox(height: 10),
                UText(
                  '${((pct ?? 0) * 100).round()}%',
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 18,
                    color: scheme.onSurface,
                    letterSpacing: 0.5,
                  ),
                ),
              ],
              const SizedBox(height: 20),
              const Text.rich(
                TextSpan(
                  children: [
                    TextSpan(text: 'LOADING AKN ZONE'),
                    WidgetSpan(
                      alignment: PlaceholderAlignment.top,
                      child: Padding(
                        padding: EdgeInsets.only(left: 2),
                        child: UText(
                          '©',
                          style: TextStyle(
                            fontSize: 9,
                            fontWeight: FontWeight.w700,
                            color: Color(0xFF3A1F26),
                            height: 1.0,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 16,
                  color: Color(0xFF3A1F26),
                  letterSpacing: 1.2,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 2),
              const UText(
                'LATEST DESIGNS',
                style: TextStyle(
                  color: Color(0xFFB23A48),
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                  letterSpacing: 2.0,
                ),
              ),
              const SizedBox(height: 12),
              UText(
                subtitle,
                style: const TextStyle(
                  color: Color(0xFF6A4B53),
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.6,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 14),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                      color: const Color(0xFFB23A48).withValues(alpha: 0.18)),
                ),
                child: const UText(
                  'FIRST-TIME SETUP • ONLY ONCE',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.0,
                    color: Color(0xFFB23A48),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
