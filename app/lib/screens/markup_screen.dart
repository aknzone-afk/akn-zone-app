import 'package:catalog_app/widgets/caps_text.dart';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../config.dart';
import '../models/photo.dart';
import '../providers/providers.dart';
import '../services/markup_compositor.dart';
import '../services/photo_freshness.dart';
import '../widgets/markup_canvas.dart';

class MarkupScreen extends ConsumerStatefulWidget {
  final List<String> photoIds;
  const MarkupScreen({super.key, required this.photoIds});

  @override
  ConsumerState<MarkupScreen> createState() => _MarkupScreenState();
}

class _MarkupScreenState extends ConsumerState<MarkupScreen> {
  late final PageController _pageCtrl;
  final Map<int, MarkupCanvasController> _controllers = {};
  // photoId → the un-marked base image the strokes are drawn over (so re-opening
  // a saved edit restores editable strokes and Undo keeps working).
  final Map<String, Uint8List?> _baseBytes = {};

  /// Drive version each base was drawn on (fresh download, or the saved
  /// edit's recorded version).
  final Map<String, String> _baseVersions = {};

  /// Photos whose base came from a saved edit rather than a fresh download.
  final Set<String> _baseFromDisk = {};
  final Set<String> _prepared = {};
  final Set<String> _prepareDone = {};
  int _current = 0;
  bool _saving = false;
  bool _clearing = false;

  @override
  void initState() {
    super.initState();
    _pageCtrl = PageController();
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    _pageCtrl.dispose();
    super.dispose();
  }

  MarkupCanvasController _ctrlFor(int index) {
    return _controllers.putIfAbsent(
      index,
      () => MarkupCanvasController(
        color: Color(kMarkupPaletteARGB.first),
        strokeWidth: kMarkupDefaultStrokeWidth,
      ),
    );
  }

  Photo? _photoAt(int i, List<Photo> all) {
    final id = widget.photoIds[i];
    for (final p in all) {
      if (p.id == id) return p;
    }
    return null;
  }

  Future<Uint8List?> _downloadOriginal(Photo photo) async {
    final dio = ref.read(dioProvider);
    try {
      final res = await dio.get<List<int>>(
        photo.detailUrl(),
        options: Options(responseType: ResponseType.bytes),
      );
      final version = normalizeEtag(res.headers.value('etag'));
      if (version != null) _baseVersions[photo.id] = version;
      return Uint8List.fromList(res.data ?? const []);
    } catch (_) {
      return null;
    }
  }

  /// Loads the canvas base + restores editable strokes for [photo] (once).
  /// Base = the saved clean base if re-editable, else a legacy baked edit,
  /// else the fresh Drive original.
  Future<void> _prepare(int index, Photo photo) async {
    if (_prepared.contains(photo.id)) return;
    _prepared.add(photo.id);
    final svc = ref.read(editServiceProvider);
    Uint8List? base = await svc.readBase(photo.id);
    base ??= await svc.read(photo.id); // legacy baked edit (no clean base)
    if (base != null) {
      _baseFromDisk.add(photo.id);
      final drawnOn = await svc.readVersion(photo.id);
      if (drawnOn != null) _baseVersions[photo.id] = drawnOn;
    }
    base ??= await _downloadOriginal(photo); // fresh photo
    final strokesJson = await svc.readStrokes(photo.id);
    if (strokesJson != null) {
      try {
        _ctrlFor(index).restoreStrokes(decodeMarkupStrokes(strokesJson));
      } catch (_) {/* ignore corrupt strokes */}
    }
    _baseBytes[photo.id] = base;
    _prepareDone.add(photo.id);
    if (mounted) setState(() {});
  }

  /// Discard the current pencil strokes AND any previously-saved edit, so
  /// the photo reverts to its original Drive image and the user starts fresh.
  Future<void> _clearAll() async {
    if (_clearing) return;
    final all = ref.read(photosProvider);
    final photo = _photoAt(_current, all);
    if (photo == null) return;
    setState(() => _clearing = true);
    try {
      // Wipe the saved edit (PNG + base + strokes) and revert the canvas to the
      // fresh Drive original with no strokes.
      await ref.read(editsProvider.notifier).markRemoved(photo.id);
      _ctrlFor(_current).clear();
      _baseFromDisk.remove(photo.id);
      _baseVersions.remove(photo.id);
      _baseBytes[photo.id] = await _downloadOriginal(photo);
    } finally {
      if (mounted) setState(() => _clearing = false);
    }
  }

  /// Composite the current markup over the photo and save it INTO THE CART:
  ///   - writes the PNG bytes to the app's local edits/ folder
  ///   - marks the photo as edited so cart shows the edited version
  ///   - adds the photo to the cart if it isn't already there
  Future<void> _saveCurrent() async {
    if (_saving) return;
    final all = ref.read(photosProvider);
    final photo = _photoAt(_current, all);
    if (photo == null) return;
    final wasAlreadyInCart = ref.read(favoritesProvider).contains(photo.id);
    setState(() => _saving = true);
    try {
      final svc = ref.read(editServiceProvider);
      // The photo was replaced on Drive while this editor was open, so its
      // saved edit (and base) were dropped: draw on the current photo instead.
      if (_baseFromDisk.contains(photo.id) &&
          await svc.readBase(photo.id) == null &&
          !await svc.exists(photo.id)) {
        _baseFromDisk.remove(photo.id);
        _baseVersions.remove(photo.id);
        _baseBytes[photo.id] = await _downloadOriginal(photo);
      }
      final base = _baseBytes[photo.id] ?? await _downloadOriginal(photo);
      if (base == null) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: UText("Couldn't load photo. Check connection.")),
        );
        return;
      }
      final ctrl = _controllers[_current];
      Uint8List outBytes;
      if (ctrl != null && ctrl.hasStrokes && ctrl.canvasSize != Size.zero) {
        outBytes = await MarkupCompositor.composite(
          originalBytes: base,
          strokes: ctrl.strokes,
          canvasSize: ctrl.canvasSize,
        );
      } else {
        outBytes = base;
      }
      // 0. Record which Drive version it's drawn on before the edit becomes
      // visible, so a concurrent check never judges it without one.
      final baseVersion = _baseVersions[photo.id];
      if (baseVersion != null) await svc.saveVersion(photo.id, baseVersion);
      // 1. Write the flattened edit (shown in the cart).
      final savedFile = await svc.save(photo.id, outBytes);
      // 1a. Keep the clean base + editable strokes so re-opening this photo
      // restores the marks and Undo keeps working.
      await svc.saveBase(photo.id, base);
      await svc.saveStrokes(
          photo.id, encodeMarkupStrokes(ctrl?.strokes ?? const []));
      // 1b. Evict any stale FileImage cached against this path so the cart
      // tile re-decodes from disk on the next paint (Flutter's image cache
      // keys by file path, not mtime).
      await FileImage(savedFile).evict();
      // 2. Tell the editsProvider so any cart tiles repaint with the edit
      // (bumps the per-id version → ValueKey changes → widget remounts).
      await ref.read(editsProvider.notifier).markSaved(photo.id);
      // 3. Make sure the photo is in the cart so the customer can find it.
      if (!ref.read(favoritesProvider).contains(photo.id)) {
        await ref.read(favoritesProvider.notifier).toggle(photo.id);
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: UText(wasAlreadyInCart ? 'Saved' : 'Saved into your cart'),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 2),
        ),
      );
      // Jump back to wherever the user came from. canPop guards the edge
      // case where someone deep-linked straight into /markup (no previous
      // route on the stack) — in that case we send them to the cart so the
      // app never gets stuck on the editor.
      if (context.canPop()) {
        context.pop();
      } else {
        context.go('/favorites');
      }
      return;
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: UText('Save failed: $e')),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final all = ref.watch(photosProvider);
    final favs = ref.watch(favoritesProvider);
    final ids = widget.photoIds;
    final ctrl = _ctrlFor(_current);
    final currentId = _current < ids.length ? ids[_current] : null;
    final alreadyInCart = currentId != null && favs.contains(currentId);

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: UText('Mark up  ${_current + 1}/${ids.length}'),
        actions: [
          // Wrap in ListenableBuilder so the button's enabled/disabled state
          // tracks the canvas controller live (the screen's AppBar otherwise
          // doesn't rebuild when strokes are added/removed — that was the
          // "undo not working" bug: the button stayed disabled after drawing).
          ListenableBuilder(
            listenable: ctrl,
            builder: (context, _) => TextButton.icon(
              onPressed: ctrl.hasStrokes ? () => ctrl.undo() : null,
              icon: const Icon(Icons.undo, color: Colors.white),
              label: const UText('UNDO',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.0,
                  )),
            ),
          ),
          TextButton.icon(
            onPressed: _clearing ? null : _clearAll,
            icon: _clearing
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.layers_clear_outlined, color: Colors.white),
            label: const UText('CLEAR',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.0,
                )),
          ),
          const SizedBox(width: 6),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: PageView.builder(
              controller: _pageCtrl,
              itemCount: ids.length,
              onPageChanged: (i) => setState(() => _current = i),
              itemBuilder: (context, i) {
                final photo = _photoAt(i, all);
                if (photo == null) {
                  return const Center(
                    child: UText('Photo missing.',
                        style: TextStyle(color: Colors.white)),
                  );
                }
                _prepare(i, photo); // lazy-load base + restore strokes (once)
                final base = _baseBytes[photo.id];
                final Widget child;
                if (!_prepareDone.contains(photo.id)) {
                  child = const Center(
                      child: CircularProgressIndicator(color: Colors.white));
                } else if (base == null || base.isEmpty) {
                  child = const Center(
                      child: Icon(Icons.broken_image_outlined,
                          color: Colors.white));
                } else {
                  child = Image.memory(base,
                      fit: BoxFit.contain, gaplessPlayback: true);
                }
                return Center(
                  child: AspectRatio(
                    aspectRatio: 3 / 4,
                    child: MarkupCanvas(controller: _ctrlFor(i), child: child),
                  ),
                );
              },
            ),
          ),
          _Toolbar(controller: ctrl),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
              child: Center(
                child: FilledButton.icon(
                  onPressed: _saving ? null : _saveCurrent,
                  icon: _saving
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.save_alt_rounded),
                  label: UText(
                    _saving
                        ? 'Saving…'
                        : (alreadyInCart ? 'SAVE' : 'SEND TO CART'),
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.8,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Toolbar extends StatefulWidget {
  final MarkupCanvasController controller;
  const _Toolbar({required this.controller});

  @override
  State<_Toolbar> createState() => _ToolbarState();
}

class _ToolbarState extends State<_Toolbar> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onChange);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChange);
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _Toolbar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onChange);
      widget.controller.addListener(_onChange);
    }
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          ...kMarkupPaletteARGB.map((argb) {
            final c = Color(argb);
            final selected = widget.controller.color.toARGB32() == argb;
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: GestureDetector(
                onTap: () => widget.controller.setColor(c),
                child: Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    color: c,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: selected ? Colors.white : Colors.white24,
                      width: selected ? 2.5 : 1.0,
                    ),
                  ),
                ),
              ),
            );
          }),
          const SizedBox(width: 8),
          Expanded(
            child: Slider(
              min: 2,
              max: 22,
              value: widget.controller.strokeWidth,
              onChanged: widget.controller.setStrokeWidth,
              activeColor: Colors.white,
              inactiveColor: Colors.white24,
            ),
          ),
        ],
      ),
    );
  }
}
