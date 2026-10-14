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
class DailyDay {
  final String date; // yyyy-mm-dd
  final List<String> ids;
  const DailyDay(this.date, this.ids);
}

final dailyFeedProvider = FutureProvider<List<DailyDay>>((ref) async {
  final r = await Dio().get<String>(
      '$kDataBase/app/daily-feed.json?t=${DateTime.now().millisecondsSinceEpoch ~/ 300000}',
      options: Options(responseType: ResponseType.plain, receiveTimeout: const Duration(seconds: 20)));
  final j = jsonDecode(r.data ?? '{}') as Map<String, dynamic>;
  return [
    for (final d in (j['days'] as List? ?? const []))
      DailyDay('${d['d']}', [for (final it in (d['items'] as List? ?? const [])) '${it['i']}']),
  ];
});

/// How many designs came today (for the badge on the home button).
final dailyTodayCountProvider = Provider<int>((ref) {
  final days = ref.watch(dailyFeedProvider).value ?? const <DailyDay>[];
  final now = DateTime.now();
  final today = '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
  return days.where((d) => d.date == today).fold(0, (t, d) => t + d.ids.length);
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

List<Photo> _photosFor(WidgetRef ref, List<String> ids) {
  final byId = {for (final p in ref.watch(photosProvider)) p.id: p};
  return [for (final i in ids) if (byId[i] != null) byId[i]!];
}

class DailyFeedScreen extends ConsumerWidget {
  const DailyFeedScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
          final shown = [for (final d in days) (d, _photosFor(ref, d.ids))].where((x) => x.$2.isNotEmpty).toList();
          if (shown.isEmpty) return const Center(child: Text('No new designs yet.'));
          // Chat style: newest at the bottom, list starts at the bottom.
          return ListView.builder(
            reverse: true,
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
            itemCount: shown.length,
            itemBuilder: (_, i) => _DayBubble(day: shown[i].$1, photos: shown[i].$2),
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
    final photos = day == null ? const <Photo>[] : _photosFor(ref, day.ids);
    return Scaffold(
      appBar: AppBar(title: UText(_label(date))),
      body: photos.isEmpty ? const Center(child: Text('No designs for this day.')) : PhotoGrid(photos: photos),
    );
  }
}
