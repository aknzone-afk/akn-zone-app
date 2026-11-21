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
import 'package:catalog_app/services/old_designs.dart';
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

    // the order screen, scrolled to the "Designs not in app" box with one row filled in
    // (nothing is sent: PLACE ORDER is never tapped)
    appRouter.push('/order');
    await wait(t, 10);
    try {
      final box = find.byKey(const ValueKey('old-designs-box'));
      await t.scrollUntilVisible(box, 400, scrollable: find.byType(Scrollable).first, maxScrolls: 30);
      // a design that is in the shop's full photo set but NOT in the app
      final idx = await OldDesigns.index(container.read(dioProvider));
      final inApp = {
        for (final p in container.read(catalogPhotosProvider)) OldDesigns.catalogKey(p.designNumber ?? p.filename),
      };
      final key = idx.entries.where((e) => e.value.length >= 3 && !inApp.contains(e.key)).map((e) => e.key).firstOrNull ?? '3549';
      await t.enterText(find.byKey(const ValueKey('old-find')), key);
      await t.tap(find.byKey(const ValueKey('old-find-btn')));
      await wait(t, 12); // the index, then the photos
      await t.ensureVisible(box);
      await shot('07b_order_old_designs', settle: 6);
      // tap the first photo -> the same select screen as any design
      await t.tap(find.byKey(const ValueKey('old-photo-0')));
      await shot('07c_old_design_select', settle: 12);
      appRouter.pop();
      await wait(t, 3);
    } catch (e) {
      debugPrint('order screen shot: $e');
      await shot('07b_order_old_designs', settle: 4);
    }

    appRouter.go('/orders');
    await shot('08_orders', settle: 10);

    appRouter.go('/chat');
    await shot('09_chat', settle: 10);
  }, timeout: const Timeout(Duration(minutes: 15)));
}
