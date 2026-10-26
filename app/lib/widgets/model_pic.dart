import 'dart:async';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../services/photo_freshness.dart' show photoCacheManager;

/// Owner 26-Oct: the modelling photo (12 X 18 file) of a design.
///
/// Every load goes through [photoCacheManager] — the shared store. The first
/// version used a plain CachedNetworkImage, i.e. DefaultCacheManager(), which
/// prunes that same store to 200 files and showed "Photo not available" on
/// the first tap. A fetch is retried, so when the button is shown the photo
/// always comes; nothing here ever says "not available".
final Set<String> _warmed = {};

/// Download into the cache (no-op when already there) so the first tap shows
/// the photo instantly. Fire-and-forget.
void warmModelPic(String url) {
  if (!_warmed.add(url)) return;
  unawaited(fetchModelPic(url, attempts: 2));
}

/// The cached file, downloading with retries when needed. Null only after
/// every attempt failed.
Future<File?> fetchModelPic(String url, {int attempts = 4}) async {
  for (var i = 0; i < attempts; i++) {
    try {
      final f = await photoCacheManager.getSingleFile(url).timeout(const Duration(seconds: 25));
      if (await f.length() > 0) return f;
      await photoCacheManager.removeFile(url); // empty file = broken download
    } catch (_) {}
    if (i + 1 < attempts) await Future<void>.delayed(Duration(milliseconds: 500 * (i + 1)));
  }
  _warmed.remove(url);
  return null;
}

/// Full-screen modelling photo(s). [autoClose] counts from the moment the
/// photo is on screen (not from the tap); null = stays until ✕. With
/// [giveUpAfter] the viewer closes by itself when the photo has not arrived
/// in time (the open-flash must never hold up ordering); without it the
/// viewer keeps retrying until the photo shows.
Future<void> showModelPic(
  BuildContext context,
  List<String> pics, {
  Duration? autoClose,
  Duration? giveUpAfter,
  Color barrier = Colors.black87,
}) {
  if (pics.isEmpty) return Future<void>.value();
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'close',
    barrierColor: barrier,
    transitionDuration: const Duration(milliseconds: 150),
    pageBuilder: (_, __, ___) => _ModelPicView(pics: pics, autoClose: autoClose, giveUpAfter: giveUpAfter),
  );
}

/// Small thumbnail for the SEE MODELLING PIC button (its download also warms
/// the cache for the tap).
class ModelThumb extends StatelessWidget {
  final String url;
  final double width, height;
  const ModelThumb(this.url, {super.key, this.width = 38, this.height = 42});

  @override
  Widget build(BuildContext context) {
    const fallback = ColoredBox(color: Colors.white24, child: Icon(Icons.person_rounded, color: Colors.white70));
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        width: width,
        height: height,
        child: CachedNetworkImage(
          imageUrl: url,
          cacheManager: photoCacheManager,
          fit: BoxFit.cover,
          memCacheWidth: 160,
          fadeInDuration: const Duration(milliseconds: 120),
          placeholder: (_, __) => fallback,
          errorWidget: (_, __, ___) => fallback,
        ),
      ),
    );
  }
}

class _ModelPicView extends StatefulWidget {
  final List<String> pics;
  final Duration? autoClose, giveUpAfter;
  const _ModelPicView({required this.pics, this.autoClose, this.giveUpAfter});

  @override
  State<_ModelPicView> createState() => _ModelPicViewState();
}

class _ModelPicViewState extends State<_ModelPicView> {
  Timer? _close, _giveUp;
  bool _closed = false;

  @override
  void initState() {
    super.initState();
    if (widget.giveUpAfter != null) _giveUp = Timer(widget.giveUpAfter!, _pop);
  }

  /// First photo is on screen: the open-flash may no longer give up, and the
  /// auto-close starts counting only now.
  void _onShown() {
    _giveUp?.cancel();
    if (widget.autoClose != null && _close == null) _close = Timer(widget.autoClose!, _pop);
  }

  void _pop() {
    if (_closed || !mounted) return;
    _closed = true;
    Navigator.of(context).maybePop();
  }

  @override
  void dispose() {
    _closed = true;
    _close?.cancel();
    _giveUp?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Stack(children: [
        Positioned.fill(
          child: PageView.builder(
            itemCount: widget.pics.length,
            itemBuilder: (_, i) => _ModelPage(
              url: widget.pics[i],
              bounded: widget.giveUpAfter != null,
              onShown: i == 0 ? _onShown : null,
            ),
          ),
        ),
        Positioned(
          top: 8,
          right: 8,
          child: IconButton.filled(
            style: IconButton.styleFrom(backgroundColor: Colors.black54),
            icon: const Icon(Icons.close_rounded, color: Colors.white, size: 30),
            onPressed: _pop,
          ),
        ),
      ]),
    );
  }
}

/// One photo: spinner until the cached file is there, retrying until the
/// viewer closes (or, for the bounded open-flash, until it gives up).
class _ModelPage extends StatefulWidget {
  final String url;
  final bool bounded;
  final VoidCallback? onShown;
  const _ModelPage({required this.url, required this.bounded, this.onShown});

  @override
  State<_ModelPage> createState() => _ModelPageState();
}

class _ModelPageState extends State<_ModelPage> {
  File? _file;
  bool _gone = false, _shown = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    while (mounted && !_gone) {
      final f = await fetchModelPic(widget.url, attempts: widget.bounded ? 2 : 4);
      if (!mounted || _gone) return;
      if (f != null) {
        setState(() => _file = f);
        return;
      }
      await Future<void>.delayed(const Duration(seconds: 1));
    }
  }

  /// Corrupt cached file (decode failed): drop it and download again — twice
  /// at most, so a bad file on the server cannot loop downloads.
  int _decodeFails = 0;
  void _reload() {
    if (!mounted || _gone || _file == null || ++_decodeFails > 2) return;
    _file = null;
    unawaited(photoCacheManager.removeFile(widget.url).catchError((_) {}).whenComplete(_load));
    setState(() {});
  }

  @override
  void dispose() {
    _gone = true;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final f = _file;
    if (f == null) return const Center(child: CircularProgressIndicator(color: Colors.white));
    return InteractiveViewer(
      child: Center(
        child: Image.file(
          f,
          fit: BoxFit.contain,
          gaplessPlayback: true,
          frameBuilder: (_, child, frame, __) {
            if (frame != null && !_shown) {
              _shown = true;
              widget.onShown?.call();
            }
            return child;
          },
          errorBuilder: (_, __, ___) {
            WidgetsBinding.instance.addPostFrameCallback((_) => _reload());
            return const Center(child: CircularProgressIndicator(color: Colors.white));
          },
        ),
      ),
    );
  }
}
