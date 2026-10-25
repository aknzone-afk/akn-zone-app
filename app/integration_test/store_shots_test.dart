// Store screenshots (owner 25-Oct-2026): opens the real app with the store
// review demo account and photographs the main screens. Run by the
// "Store screenshots" workflow on an Android emulator:
//   flutter drive --driver=test_driver/shots.dart --target=integration_test/store_shots_test.dart
import 'dart:convert';

import 'package:catalog_app/app.dart' show appRouter;
import 'package:catalog_app/main.dart' as app;
import 'package:catalog_app/models/photo.dart';
import 'package:catalog_app/providers/providers.dart';
import 'package:catalog_app/screens/daily_feed_screen.dart' show dailyFeedProvider;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<void> wait(WidgetTester t, int seconds) async {
    for (var i = 0; i < seconds * 4; i++) {
      await t.pump(const Duration(milliseconds: 250));
    }
  }

  testWidgets('store screenshots', (t) async {
    final p = await SharedPreferences.getInstance();
    await p.setString('account_v1', jsonEncode({
      'mobile': '9999900001', 'india': true, 'status': 'approved', 'kind': 'existing',
      'party': 'SHREE FASHION', 'cust': {'billName': 'SHREE FASHION', 'country': 'India', 'pincode': '395002',
        'address': 'Ring Road', 'kind': 'old', 'mobile': '9999900001', 'transport': 'COURIER', 'bookingPlace': 'SURAT'},
    }));
    app.main();
    await wait(t, 20);
    await binding.convertFlutterSurfaceToImage();
    await wait(t, 70); // first launch: live catalogue + covers

    Future<void> shot(String name, {int settle = 8}) async {
      await wait(t, settle);
      await binding.takeScreenshot(name);
    }

    final container = ProviderScope.containerOf(t.element(find.byType(Navigator).first));
    await shot('00_start');
    appRouter.go('/');
    await shot('01_home', settle: 12);

    // a folder full of designs
    final photos = container.read(photosProvider);
    final folders = <String, int>{};
    for (final ph in photos) {
      folders[ph.folder] = (folders[ph.folder] ?? 0) + 1;
    }
    final best = (folders.entries.toList()..sort((a, b) => b.value.compareTo(a.value))).first.key;
    appRouter.push('/folder/${Uri.encodeComponent(best)}');
    await shot('02_folder', settle: 15);

    // daily update
    appRouter.go('/');
    await wait(t, 2);
    appRouter.push('/daily');
    await shot('03_daily', settle: 15);
    final days = await container.read(dailyFeedProvider.future);
    if (days.isNotEmpty) {
      appRouter.push('/daily/${days.first.date}');
      await shot('04_daily_day', settle: 15);
    }

    // one design full screen
    final withPrice = photos.where((x) => x.price != null).toList();
    final Photo one = (withPrice.isNotEmpty ? withPrice : photos)[photos.length ~/ 3 % (withPrice.isNotEmpty ? withPrice.length : photos.length)];
    appRouter.go('/');
    await wait(t, 2);
    appRouter.push('/photo/${Uri.encodeComponent(one.id)}', extra: [one.id]);
    await shot('05_photo', settle: 15);

    // colour / set picker
    appRouter.push('/pick/${Uri.encodeComponent(one.id)}');
    await shot('06_pick', settle: 12);

    // cart with a few designs
    final fav = container.read(favoritesProvider.notifier);
    for (final ph in withPrice.take(6)) {
      await fav.add(ph.id);
    }
    appRouter.go('/favorites');
    await shot('07_cart', settle: 15);

    appRouter.go('/orders');
    await shot('08_orders', settle: 10);

    appRouter.go('/chat');
    await shot('09_chat', settle: 10);
  }, timeout: const Timeout(Duration(minutes: 15)));
}
