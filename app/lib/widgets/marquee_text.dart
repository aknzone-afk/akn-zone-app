import 'package:catalog_app/widgets/caps_text.dart';
import 'package:flutter/material.dart';

/// A single-line text that auto-scrolls (marquee) ONLY when it's too wide to
/// fit. If it fits, it renders as a normal static Text. No dependency.
///
/// Used for long folder names in app-bar titles where ellipsis would hide
/// part of the name.
class MarqueeText extends StatefulWidget {
  final String text;
  final TextStyle? style;
  final double velocity; // pixels per second
  final Duration pauseAtEnds;

  const MarqueeText(
    this.text, {
    super.key,
    this.style,
    this.velocity = 40,
    this.pauseAtEnds = const Duration(seconds: 1),
  });

  @override
  State<MarqueeText> createState() => _MarqueeTextState();
}

class _MarqueeTextState extends State<MarqueeText>
    with SingleTickerProviderStateMixin {
  final _scroll = ScrollController();
  bool _looping = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeStart());
  }

  @override
  void didUpdateWidget(covariant MarqueeText old) {
    super.didUpdateWidget(old);
    if (old.text != widget.text) {
      _looping = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) _scroll.jumpTo(0);
        _maybeStart();
      });
    }
  }

  Future<void> _maybeStart() async {
    if (!mounted || _looping) return;
    if (!_scroll.hasClients) return;
    final max = _scroll.position.maxScrollExtent;
    if (max <= 0) return; // fits — no scrolling needed
    _looping = true;
    while (mounted && _looping) {
      final extent = _scroll.position.maxScrollExtent;
      if (extent <= 0) break;
      final ms = (extent / widget.velocity * 1000).round();
      await Future<void>.delayed(widget.pauseAtEnds);
      if (!mounted || !_scroll.hasClients) break;
      await _scroll.animateTo(extent,
          duration: Duration(milliseconds: ms), curve: Curves.linear);
      await Future<void>.delayed(widget.pauseAtEnds);
      if (!mounted || !_scroll.hasClients) break;
      await _scroll.animateTo(0,
          duration: Duration(milliseconds: ms), curve: Curves.linear);
    }
  }

  @override
  void dispose() {
    _looping = false;
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      controller: _scroll,
      scrollDirection: Axis.horizontal,
      physics: const NeverScrollableScrollPhysics(),
      child: UText(widget.text, maxLines: 1, style: widget.style),
    );
  }
}
