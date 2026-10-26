import 'dart:convert';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../config.dart';
import '../models/photo.dart';
import '../providers/providers.dart';
import '../services/drive_urls.dart';
import '../services/photo_freshness.dart' show photoCacheManager;
import '../widgets/caps_text.dart';
import '../widgets/photo_grid.dart';

/// Owner 15-Oct: DAILY UPDATE like the WhatsApp broadcast — one bubble per
/// day ("15 Oct · 12 new designs"), newest at the bottom; a day opens as a
/// normal folder (select colours / sets, add to cart).
///
/// Owner 24-Oct: a day shows EXACTLY the photos the shop posted that day and
/// every one of them opens. The shop PC resolves each posted photo to its
/// current Drive id and sends the feed to the cloud straight away (GitHub
/// Pages is only the fallback), and every item carries enough (file name,
/// folder, price, fabric) to be shown even before this phone's catalogue has
/// synced it — the catalogue sync then runs in the background so ordering
/// works too. The number on the bubble is always the number that opens.
class DailyItem {
  final String id;
  final String design;
  final String folder;
  final String filename;
  final int? price;
  final String? fabric;
  const DailyItem(this.id, this.design, this.folder, this.filename, this.price, this.fabric);

  factory DailyItem.fromJson(Map<String, dynamic> j) => DailyItem(
        '${j['i']}',
        '${j['n'] ?? ''}',
        '${j['f'] ?? ''}',
        '${j['fn'] ?? ''}',
        j['p'] is num ? (j['p'] as num).toInt() : int.tryParse('${j['p'] ?? ''}'),
        j['t'] == null ? null : '${j['t']}',
      );

  Photo asPhoto() => Photo(
        id: id,
        filename: filename.isEmpty ? '$design.jpg' : filename,
        folder: folder,
        designNumber: design.isEmpty ? null : design,
        fabricName: fabric,
        price: price,
        priceText: price == null ? null : 'Rs $price/-',
        ocrText: '',
        ocrState: OcrState.done,
        lastSeen: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      );
}

class DailyDay {
  final String date; // yyyy-mm-dd
  final List<DailyItem> items;
  const DailyDay(this.date, this.items);
  List<String> get ids => [for (final it in items) it.id];
}

const _kCloud = 'https://asia-south1-akn-chat-a7dd8.cloudfunctions.net';

List<DailyDay> _parse(String body) {
  final j = jsonDecode(body) as Map<String, dynamic>;
  return [
    for (final d in (j['days'] as List? ?? const []))
      DailyDay('${d['d']}', [
        for (final it in (d['items'] as List? ?? const []))
          if (it is Map<String, dynamic> && '${it['i'] ?? ''}'.isNotEmpty) DailyItem.fromJson(it),
      ]),
  ];
}

/// Always the freshest copy: the cloud first (what the shop PC uploaded a
/// minute or two ago), GitHub Pages only when the cloud does not answer.
final dailyFeedProvider = FutureProvider<List<DailyDay>>((ref) async {
  try {
    final r = await Dio().get<String>('$_kCloud/dailyFeed',
        options: Options(
            responseType: ResponseType.plain,
            headers: const {'x-app-key': 'akn-zone-app-v3', 'Cache-Control': 'no-store'},
            receiveTimeout: const Duration(seconds: 15)));
    final days = _parse(r.data ?? '{}');
    if (days.isNotEmpty) return days;
  } catch (_) {/* fall back to the published copy */}
  final r = await Dio().get<String>('$kDataBase/app/daily-feed.json?t=${DateTime.now().millisecondsSinceEpoch}',
      options: Options(responseType: ResponseType.plain, receiveTimeout: const Duration(seconds: 20)));
  return _parse(r.data ?? '{}');
});

/// How many designs came today (for the badge on the home button).
final dailyTodayCountProvider = Provider<int>((ref) {
  final days = ref.watch(dailyFeedProvider).value ?? const <DailyDay>[];
  final now = DateTime.now();
  final today = '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
  return days.where((d) => d.date == today).fold(0, (t, d) => t + d.items.length);
});

String _label(String ymd) {
  final p = ymd.split('-').map(int.parse).toList();
  final d = DateTime(p[0], p[1], p[2]);
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final diff = today.difference(d).inDays;
  const m = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  const w = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  final pretty = '${w[d.weekday - 1]}, ${d.day} ${m[d.month - 1]}';
  if (diff == 0) return 'TODAY · $pretty';
  if (diff == 1) return 'YESTERDAY · $pretty';
  return pretty;
}

/// The day's photos: the catalogue's copy when this phone already has it
/// (prices, OCR, cart links), else the feed's own description — never a hole.
({List<Photo> photos, int missing}) _photosFor(WidgetRef ref, List<DailyItem> items) {
  final byId = {
    for (final p in ref.watch(catalogProvider).maybeWhen(data: (d) => d.photos, orElse: () => const <Photo>[])) p.id: p
  };
  final known = ref.watch(feedPhotosProvider);
  var missing = 0;
  final out = <Photo>[];
  final add = <String, Photo>{};
  for (final it in items) {
    final p = byId[it.id];
    if (p == null) {
      missing++;
      final f = known[it.id] ?? it.asPhoto();
      if (!known.containsKey(it.id)) add[it.id] = f;
      out.add(f);
    } else {
      out.add(p);
    }
  }
  // the select screen / cart look photos up by id — register the feed's own copy
  if (add.isNotEmpty) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final n = ref.read(feedPhotosProvider.notifier);
      n.state = {...n.state, ...add};
    });
  }
  return (photos: out, missing: missing);
}

bool _syncKicked = false;

/// New photos not in this phone's catalogue yet -> one background Drive sync
/// per app session (the shared, guarded walk — see pullToRefreshProvider), so
/// ordering them works a few seconds later. The screen never waits for it.
void _syncCatalogueOnce(WidgetRef ref) {
  if (_syncKicked) return;
  _syncKicked = true;
  WidgetsBinding.instance.addPostFrameCallback((_) {
    // ignore: discarded_futures
    ref.read(pullToRefreshProvider)().whenComplete(() {
      Future<void>.delayed(const Duration(minutes: 3), () => _syncKicked = false);
    });
  });
}

class DailyFeedScreen extends ConsumerStatefulWidget {
  const DailyFeedScreen({super.key});

  @override
  ConsumerState<DailyFeedScreen> createState() => _DailyFeedScreenState();
}

class _DailyFeedScreenState extends ConsumerState<DailyFeedScreen> {
  @override
  void initState() {
    super.initState();
    ref.invalidate(dailyFeedProvider); // every visit = the latest feed
  }

  @override
  Widget build(BuildContext context) {
    final feed = ref.watch(dailyFeedProvider);
    return Scaffold(
      appBar: AppBar(title: const UText('DAILY UPDATE')),
      body: feed.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, __) => Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('Could not load the daily update.'),
            TextButton(onPressed: () => ref.invalidate(dailyFeedProvider), child: const Text('TRY AGAIN')),
          ]),
        ),
        data: (days) {
          final shown = [for (final d in days) (d, _photosFor(ref, d.items))].where((x) => x.$2.photos.isNotEmpty).toList();
          if (shown.any((x) => x.$2.missing > 0)) _syncCatalogueOnce(ref);
          if (shown.isEmpty) return const Center(child: Text('No new designs yet.'));
          // Chat style: newest at the bottom, list starts at the bottom.
          return ListView.builder(
            reverse: true,
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
            itemCount: shown.length,
            itemBuilder: (_, i) => _DayBubble(day: shown[i].$1, photos: shown[i].$2.photos),
          );
        },
      ),
    );
  }
}

class _DayBubble extends StatelessWidget {
  final DailyDay day;
  final List<Photo> photos;
  const _DayBubble({required this.day, required this.photos});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            margin: const EdgeInsets.only(bottom: 8),
            decoration: BoxDecoration(color: scheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(12)),
            child: Text(_label(day.date), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 12)),
          ),
        ),
        Material(
          color: const Color(0xFFE8F5E9),
          borderRadius: BorderRadius.circular(14),
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: () => context.push('/daily/${day.date}'),
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                // the number that opens — never more than what is inside
                Text('🆕 ${photos.length} new design${photos.length == 1 ? '' : 's'}',
                    style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
                const SizedBox(height: 8),
                Row(children: [
                  for (final p in photos.take(4))
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.only(right: 4),
                        child: AspectRatio(
                          aspectRatio: 1,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: CachedNetworkImage(
                              imageUrl: DriveUrls.thumbnail(p.id, width: kThumbnailWidth),
                              cacheManager: photoCacheManager,
                              fit: BoxFit.cover,
                            ),
                          ),
                        ),
                      ),
                    ),
                  for (var k = photos.length; k < 4; k++) const Expanded(child: SizedBox()),
                ]),
                const SizedBox(height: 8),
                const Align(
                  alignment: Alignment.centerRight,
                  child: Text('OPEN  ›', style: TextStyle(fontWeight: FontWeight.w900, color: Color(0xFF1B5E20))),
                ),
              ]),
            ),
          ),
        ),
      ]),
    );
  }
}

/// One day's designs as a normal grid (select colours / sets, add to cart).
class DailyDayScreen extends ConsumerWidget {
  final String date;
  const DailyDayScreen({super.key, required this.date});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final days = ref.watch(dailyFeedProvider).value ?? const <DailyDay>[];
    final day = days.where((d) => d.date == date).firstOrNull;
    final r = day == null ? (photos: const <Photo>[], missing: 0) : _photosFor(ref, day.items);
    if (r.missing > 0) _syncCatalogueOnce(ref);
    return Scaffold(
      appBar: AppBar(title: UText(_label(date))),
      body: r.photos.isEmpty ? const Center(child: Text('No designs for this day.')) : PhotoGrid(photos: r.photos),
    );
  }
}
