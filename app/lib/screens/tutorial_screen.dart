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
  static const _kSignupIdKey = 'signup_video_id_v1';

  /// Owner 15-Oct: from where to where each video plays — set online in
  /// app-config.json (no app update): "tutorial_start" / "tutorial_end" for
  /// the how-to-order video, "signup_youtube" / "signup_start" /
  /// "signup_end" for the sign-up help video. Times: seconds or "m:ss".
  static double startAt(SharedPreferences p, {bool signup = false}) =>
      p.getDouble(signup ? 'signup_start_v1' : 'tutorial_start_v2') ?? 0;
  static double? endAt(SharedPreferences p, {bool signup = false}) {
    final v = p.getDouble(signup ? 'signup_end_v1' : 'tutorial_end_v1') ?? 0;
    return v > 0 ? v : null;
  }

  static String? videoId(SharedPreferences p, {bool signup = false}) {
    final v = p.getString(signup ? _kSignupIdKey : _kIdKey);
    return (v == null || v.isEmpty) ? null : v;
  }

  /// 199, "199", "3:19" -> seconds (0 = not set).
  static double secs(Object? raw) {
    if (raw is num) return raw.toDouble();
    final t = '${raw ?? ''}'.trim();
    if (t.contains(':')) {
      var total = 0.0;
      for (final part in t.split(':')) {
        total = total * 60 + (double.tryParse(part.trim()) ?? 0);
      }
      return total;
    }
    return double.tryParse(t) ?? 0;
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
      await p.setDouble('tutorial_start_v2', secs(j['tutorial_start']));
      await p.setDouble('tutorial_end_v1', secs(j['tutorial_end']));
      // Sign-up help video: its own link, else the same video.
      final su = parseId('${j['signup_youtube'] ?? ''}') ?? id;
      await p.setString(_kSignupIdKey, su ?? '');
      await p.setDouble('signup_start_v1', secs(j['signup_start']));
      await p.setDouble('signup_end_v1', secs(j['signup_end']));
    } catch (_) {}
  }
}

class TutorialScreen extends ConsumerStatefulWidget {
  final bool mustWatch;
  final bool signup; // the sign-up help video (owner 15-Oct)
  const TutorialScreen({super.key, this.mustWatch = false, this.signup = false});

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
    final prefs = ref.read(sharedPreferencesProvider);
    final id = Tutorial.videoId(prefs, signup: widget.signup);
    if (id == null) {
      _failed = true;
      return;
    }
    _ctrl = YoutubePlayerController.fromVideoId(
      videoId: id,
      startSeconds: Tutorial.startAt(prefs, signup: widget.signup),
      endSeconds: Tutorial.endAt(prefs, signup: widget.signup),
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
    if (widget.signup) {
      // Opened from the sign-up form (outside the app's router).
      if (mounted) Navigator.of(context).maybePop();
      return;
    }
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
          title: UText(widget.signup ? 'How to sign up' : 'How to order',
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
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 14),
              child: Text(
                widget.signup
                    ? 'Watch this short video to learn how to fill in your details and sign up.'
                    : 'Watch this short video to learn how to select designs and place your order.',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70, fontSize: 15, height: 1.3),
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
