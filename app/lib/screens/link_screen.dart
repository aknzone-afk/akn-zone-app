import 'dart:async';

import 'package:catalog_app/widgets/caps_text.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../models/photo.dart';
import '../providers/providers.dart';
import 'photo_detail_screen.dart';

/// Lands a link from a video / reel / WhatsApp straight on the right designs.
///
///   https://bbsynthetics.in/d/1444            → design 1444
///   https://bbsynthetics.in/d/1444,1502,1610  → those three, swipeable
///   https://bbsynthetics.in/f/banarasi        → that folder
///   aknzone://open/d/1444                     → same, via the app scheme
///
/// The catalog may still be loading when the link arrives, so this waits for
/// it instead of failing.
class DesignLinkScreen extends ConsumerStatefulWidget {
  final String designs;
  const DesignLinkScreen({super.key, required this.designs});

  @override
  ConsumerState<DesignLinkScreen> createState() => _DesignLinkScreenState();
}

String _norm(String s) => s.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');

class _DesignLinkScreenState extends ConsumerState<DesignLinkScreen> {
  bool _gaveUp = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer(const Duration(seconds: 25), () {
      if (mounted) setState(() => _gaveUp = true);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final wanted = widget.designs
        .split(RegExp(r'[,\s+]+'))
        .map(_norm)
        .where((s) => s.isNotEmpty)
        .toList();
    final photos = ref.watch(photosProvider);
    final catalog = ref.watch(catalogProvider);
    final loaded = catalog.hasValue || _gaveUp;

    final found = <Photo>[];
    for (final w in wanted) {
      // Exact design number first; fall back to the number inside the name.
      var hits = photos.where((p) => _norm(p.designNumber ?? '') == w).toList();
      if (hits.isEmpty) {
        hits = photos
            .where((p) => _norm(p.filename.split('.').first) == w)
            .toList();
      }
      found.addAll(hits.where((h) => !found.contains(h)));
    }

    if (found.isNotEmpty) {
      return PhotoDetailScreen(
        initialPhotoId: found.first.id,
        photoIds: found.map((p) => p.id).toList(),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const UText('AKN ZONE')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: !loaded || photos.isEmpty && !_gaveUp
              ? Column(mainAxisSize: MainAxisSize.min, children: [
                  const CircularProgressIndicator(),
                  const SizedBox(height: 16),
                  UText('Opening design ${wanted.join(', ')}…',
                      textAlign: TextAlign.center),
                ])
              : Column(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.search_off_rounded, size: 48),
                  const SizedBox(height: 12),
                  UText('Design ${wanted.join(', ')} is not in the catalog now.',
                      textAlign: TextAlign.center),
                  const SizedBox(height: 6),
                  const UText('It may be sold out. See our latest designs:',
                      textAlign: TextAlign.center),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: () => context.go('/'),
                    child: const UText('Open catalog'),
                  ),
                ]),
        ),
      ),
    );
  }
}

/// `/f/<name>` → the folder whose name matches (spaces, case and punctuation
/// ignored; a unique partial match is accepted too).
class FolderLinkScreen extends ConsumerWidget {
  final String name;
  const FolderLinkScreen({super.key, required this.name});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final photos = ref.watch(photosProvider);
    final catalog = ref.watch(catalogProvider);
    final want = _norm(name);
    final paths = <String>{};
    for (final p in photos) {
      final segs = p.folder.split('/');
      for (var i = 1; i <= segs.length; i++) {
        paths.add(segs.sublist(0, i).join('/'));
      }
    }
    String? hit;
    for (final path in paths) {
      if (_norm(path.split('/').last) == want || _norm(path) == want) {
        hit = path;
        break;
      }
    }
    if (hit == null) {
      final partial =
          paths.where((p) => _norm(p.split('/').last).contains(want)).toList();
      if (partial.length == 1) hit = partial.first;
    }
    if (hit != null) {
      final target = hit;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted) {
          context.replace('/folder/${Uri.encodeComponent(target)}');
        }
      });
    } else if (catalog.hasValue && photos.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted) context.go('/');
      });
    }
    return const Scaffold(body: Center(child: CircularProgressIndicator()));
  }
}
