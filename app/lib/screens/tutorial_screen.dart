import 'dart:async';
import 'dart:convert';

import 'package:catalog_app/widgets/caps_text.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:youtube_player_iframe/youtube_player_iframe.dart';

import '../config.dart';
import '../providers/providers.dart';

/// "How to order" video (owner, 11-Oct-2026): the owner's live demo on
/// YouTube (unlisted — free). First open: must be watched to the end before
/// the app continues. The ❓ button on the home screen plays it again.
/// The video id lives on the website (app/app-config.json "tutorial_youtube"),
/// so a new video needs no app update. No id yet → nothing is shown.
class Tutorial {
  static const _kIdKey = 'tutorial_id_v1';
  static const _kSeenKey = 'tutorial_seen_v1';
  static const _kStartKey = 'tutorial_start_v1';

  /// Owner 15-Oct: where the video starts (seconds) — app-config
  /// "tutorial_start", so it can change without an app update.
  static double startAt(SharedPreferences p) => (p.getInt(_kStartKey) ?? 0).toDouble();

  static String? videoId(SharedPreferences p) {
    final v = p.getString(_kIdKey);
    return (v == null || v.isEmpty) ? null : v;
  }

  static bool mustWatch(SharedPreferences p) {
    final id = videoId(p);
    return id != null && p.getString(_kSeenKey) != id;
  }

  static Future<void> markSeen(SharedPreferences p) async {
    final id = videoId(p);
    if (id != null) await p.setString(_kSeenKey, id);
  }

  /// Accepts a full YouTube link or a bare id.
  static String? parseId(String raw) {
    final s = raw.trim();
    if (s.isEmpty) return null;
    final m = RegExp(r'(?:v=|youtu\.be/|shorts/|embed/|live/)([A-Za-z0-9_-]{11})').firstMatch(s);
    if (m != null) return m.group(1);
    return RegExp(r'^[A-Za-z0-9_-]{11}$').hasMatch(s) ? s : null;
  }

  static Future<void> refresh(SharedPreferences p, Dio dio) async {
    try {
      final res = await dio.get<dynamic>(
        '$kDataBase/app/app-config.json?t=${DateTime.now().millisecondsSinceEpoch ~/ 600000}',
        options: Options(responseType: ResponseType.plain),
      );
      final j = jsonDecode('${res.data}') as Map<String, dynamic>;
      // 3.1.26+: own key — old versions (forced, from 0:00, no cross) keep
      // reading "tutorial_youtube", which stays empty.
      final id = parseId('${j['tutorial_youtube_v2'] ?? ''}');
      await p.setString(_kIdKey, id ?? '');
      await p.setInt(_kStartKey, (j['tutorial_start'] as num?)?.toInt() ?? 0);
    } catch (_) {}
  }
}

class TutorialScreen extends ConsumerStatefulWidget {
  final bool mustWatch;
  const TutorialScreen({super.key, this.mustWatch = false});

  @override
  ConsumerState<TutorialScreen> createState() => _TutorialScreenState();
}

class _TutorialScreenState extends ConsumerState<TutorialScreen> {
  YoutubePlayerController? _ctrl;
  StreamSubscription? _sub;
  bool _ended = false;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    final id = Tutorial.videoId(ref.read(sharedPreferencesProvider));
    if (id == null) {
      _failed = true;
      return;
    }
    _ctrl = YoutubePlayerController.fromVideoId(
      videoId: id,
      startSeconds: Tutorial.startAt(ref.read(sharedPreferencesProvider)),
      autoPlay: true,
      params: const YoutubePlayerParams(
        showFullscreenButton: true,
        showControls: true,
        strictRelatedVideos: true,
      ),
    );
    _sub = _ctrl!.listen((v) {
      if (!mounted) return;
      if (v.playerState == PlayerState.ended && !_ended) {
        setState(() => _ended = true);
      }
      if (v.hasError && !_failed) setState(() => _failed = true);
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _ctrl?.close();
    super.dispose();
  }

  Future<void> _continue() async {
    await Tutorial.markSeen(ref.read(sharedPreferencesProvider));
    if (!mounted) return;
    if (context.canPop()) {
      context.pop();
    } else {
      context.go('/');
    }
  }

  @override
  Widget build(BuildContext context) {
    // Must-watch: the button unlocks when the video ends (or if it cannot
    // play at all, so nobody is ever locked out).
    final canGo = !widget.mustWatch || _ended || _failed;
    return PopScope(
      canPop: canGo,
      child: Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
          automaticallyImplyLeading: canGo,
          title: const UText('How to order',
              style: TextStyle(color: Colors.white)),
          // Owner 15-Oct: a cross — whoever does not want the video skips it
          // (counts as seen, so it is not shown again).
          actions: [
            IconButton(
              tooltip: 'Skip',
              icon: const Icon(Icons.close_rounded, size: 28),
              onPressed: _continue,
            ),
          ],
        ),
        body: Column(
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 8, 16, 14),
              child: Text(
                'Watch this short video to learn how to select designs and place your order.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white70, fontSize: 15, height: 1.3),
              ),
            ),
            if (_ctrl != null)
              YoutubePlayer(controller: _ctrl!, aspectRatio: 16 / 9)
            else
              const Padding(
                padding: EdgeInsets.all(24),
                child: Text('Video coming soon.',
                    style: TextStyle(color: Colors.white70)),
              ),
            const Spacer(),
          ],
        ),
        bottomNavigationBar: SafeArea(
          minimum: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: SizedBox(
            height: 54,
            child: FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF1B8E3A),
                disabledBackgroundColor: Colors.white12,
              ),
              onPressed: canGo ? _continue : null,
              child: Text(
                canGo ? 'CONTINUE' : 'Please watch the full video to continue',
                style: const TextStyle(fontWeight: FontWeight.w800, letterSpacing: 0.5),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
