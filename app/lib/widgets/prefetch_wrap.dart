import 'package:flutter/widgets.dart';

import '../services/thumb_prefetcher.dart';

/// Wraps a child widget and fires `ThumbPrefetcher.warmCache(urls)` whenever
/// the URL list reference changes. Use it around any photo grid so the
/// thumbnails are downloaded into the shared cache the moment the screen
/// opens, eliminating the blank-tile-then-pop pattern.
class PrefetchOnChange extends StatefulWidget {
  final List<String> urls;
  final Widget child;
  const PrefetchOnChange({super.key, required this.urls, required this.child});

  @override
  State<PrefetchOnChange> createState() => _PrefetchOnChangeState();
}

class _PrefetchOnChangeState extends State<PrefetchOnChange> {
  @override
  void initState() {
    super.initState();
    ThumbPrefetcher.warmCache(widget.urls);
  }

  @override
  void didUpdateWidget(covariant PrefetchOnChange old) {
    super.didUpdateWidget(old);
    if (old.urls.length != widget.urls.length ||
        (widget.urls.isNotEmpty &&
            old.urls.isNotEmpty &&
            (widget.urls.first != old.urls.first ||
                widget.urls.last != old.urls.last))) {
      ThumbPrefetcher.warmCache(widget.urls);
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
