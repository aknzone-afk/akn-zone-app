// 20-Nov-2026 — the 3.1.55 safety nets, each with the failure it guards against:
//  * SafeRouteParser: a location go_router cannot digest ("daily" from a tapped
//    push, "" from a half-started router) used to throw and leave the app on a
//    dead grey screen.
//  * photoFetchOrder / PatientFileService: a photo is fetched from Google's
//    image host directly, then through Drive, with the cache key unchanged.
//  * dataMirrorUrls: three backup copies of the app's data files.

import 'package:catalog_app/app.dart' show SafeRouteParser;
import 'package:catalog_app/services/photo_freshness.dart';
import 'package:catalog_app/services/region_fallback.dart';
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

GoRouter _router() => GoRouter(
      errorBuilder: (_, __) => const Scaffold(body: Text('HOME')),
      routes: [
        GoRoute(path: '/', builder: (_, __) => const Scaffold(body: Text('HOME'))),
        GoRoute(path: '/chat', builder: (_, __) => const Scaffold(body: Text('CHAT'))),
        GoRoute(path: '/daily', builder: (_, __) => const Scaffold(body: Text('DAILY'))),
        GoRoute(path: '/daily/:date', builder: (_, s) => Scaffold(body: Text('DAY ${s.pathParameters['date']}'))),
      ],
    );

RouterConfig<RouteMatchList> _safe(GoRouter r) => RouterConfig<RouteMatchList>(
      routeInformationProvider: r.routeInformationProvider,
      routeInformationParser: SafeRouteParser(r.routeInformationParser),
      routerDelegate: r.routerDelegate,
      backButtonDispatcher: r.backButtonDispatcher,
    );

class _FakeResponse implements FileServiceResponse {
  _FakeResponse(this.statusCode);
  @override
  final int statusCode;
  bool drained = false;
  @override
  Stream<List<int>> get content => Stream<List<int>>.fromIterable([
        [1, 2, 3]
      ]).map((x) {
        drained = true;
        return x;
      });
  @override
  int? get contentLength => 3;
  @override
  String? get eTag => '"v2"';
  @override
  String get fileExtension => '.jpg';
  @override
  DateTime get validTill => DateTime.now().add(const Duration(days: 7));
}

class _FakeService extends FileService {
  _FakeService(this.answers);

  /// url -> status code to answer, or an Object to throw
  final Map<String, List<Object>> answers;
  final List<String> asked = [];

  @override
  Future<FileServiceResponse> get(String url, {Map<String, String>? headers}) async {
    asked.add(url);
    final list = answers[url] ?? const <Object>[500];
    final a = list.length > 1 ? list.removeAt(0) : list.first;
    if (a is int) return _FakeResponse(a);
    throw a;
  }
}

void main() {
  const drive = 'https://drive.google.com/thumbnail?id=12rFxs_9xf4Gsi9j7FCA7aW8N7fYIgAsS&sz=w600';
  const direct = 'https://lh3.googleusercontent.com/d/12rFxs_9xf4Gsi9j7FCA7aW8N7fYIgAsS=w600';

  group('router', () {
    testWidgets('plain go_router DOES fail on the push route "daily" (the bug)', (t) async {
      t.binding.platformDispatcher.defaultRouteNameTestValue = 'daily';
      addTearDown(t.binding.platformDispatcher.clearDefaultRouteNameTestValue);
      await t.pumpWidget(MaterialApp.router(routerConfig: _router()));
      await t.pump();
      expect(t.takeException(), isNotNull, reason: 'if this stops failing, go_router fixed it upstream');
    });

    testWidgets('with the safe parser the same start opens the catalogue', (t) async {
      t.binding.platformDispatcher.defaultRouteNameTestValue = 'daily';
      addTearDown(t.binding.platformDispatcher.clearDefaultRouteNameTestValue);
      final r = _router();
      await t.pumpWidget(MaterialApp.router(routerConfig: _safe(r)));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      expect(find.text('HOME'), findsOneWidget);
      // and the app still navigates normally afterwards
      r.push('/daily');
      await t.pumpAndSettle();
      expect(find.text('DAILY'), findsOneWidget);
      expect(await r.routerDelegate.popRoute(), isTrue);
      await t.pumpAndSettle();
      expect(find.text('HOME'), findsOneWidget);
    });

    testWidgets('a good first page is left alone ("/daily" from a link)', (t) async {
      t.binding.platformDispatcher.defaultRouteNameTestValue = '/daily';
      addTearDown(t.binding.platformDispatcher.clearDefaultRouteNameTestValue);
      await t.pumpWidget(MaterialApp.router(routerConfig: _safe(_router())));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      expect(find.text('DAILY'), findsOneWidget);
    });

    testWidgets('a saved state with an EMPTY location (the follow-on crash) opens the catalogue', (t) async {
      final r = _router();
      await t.pumpWidget(MaterialApp.router(routerConfig: _safe(r)));
      await t.pumpAndSettle();
      final ctx = t.element(find.text('HOME'));
      final broken = RouteInformation(uri: Uri.parse(''), state: <Object?, Object?>{
        'location': '',
        'state': <Object?, Object?>{'codec': 'json', 'encoded': 'null'},
      });
      // the plain parser throws on it …
      Object? plain;
      try {
        await r.routeInformationParser.parseRouteInformationWithDependencies(broken, ctx);
      } catch (e) {
        plain = e;
      }
      expect(plain, isNotNull, reason: 'if this stops failing, go_router fixed it upstream');
      // … the safe one answers with the home page
      final got = await SafeRouteParser(r.routeInformationParser).parseRouteInformationWithDependencies(broken, ctx);
      expect(got.uri.path, '/');
      expect(got.isError, isFalse);
    });

    testWidgets('gate flip (Router unmounted and mounted again) after a bad start keeps working', (t) async {
      t.binding.platformDispatcher.defaultRouteNameTestValue = 'daily';
      addTearDown(t.binding.platformDispatcher.clearDefaultRouteNameTestValue);
      final r = _router();
      final cfg = _safe(r);
      final allowed = ValueNotifier<bool>(true);
      Widget app() => MaterialApp.router(
            routerConfig: cfg,
            builder: (_, child) => ValueListenableBuilder<bool>(
                valueListenable: allowed,
                builder: (_, ok, __) => ok ? child! : const Center(child: CircularProgressIndicator())),
          );
      await t.pumpWidget(app());
      await t.pumpAndSettle();
      expect(find.text('HOME'), findsOneWidget);
      for (var i = 0; i < 3; i++) {
        allowed.value = false; // the access gate shows its spinner: the Router leaves the tree
        await t.pump();
        allowed.value = true; // … and comes back
        await t.pumpAndSettle();
        expect(t.takeException(), isNull);
        expect(find.text('HOME'), findsOneWidget);
      }
      // BACK must still have exactly one listener ("Bad state: Too many elements" was the symptom)
      r.push('/chat');
      await t.pumpAndSettle();
      expect(find.text('CHAT'), findsOneWidget);
      await t.binding.handlePopRoute();
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      expect(find.text('HOME'), findsOneWidget);
    });
  });

  group('photos', () {
    test('a Drive thumbnail is asked for at the image host directly', () {
      expect(driveDirectUrl(drive), direct);
      expect(driveDirectUrl('https://drive.google.com/thumbnail?id=12rFxs_9xf4Gsi9j7FCA7aW8N7fYIgAsS&sz=w2000'),
          'https://lh3.googleusercontent.com/d/12rFxs_9xf4Gsi9j7FCA7aW8N7fYIgAsS=w2000');
      expect(driveDirectUrl('https://drive.google.com/thumbnail?id=12rFxs_9xf4Gsi9j7FCA7aW8N7fYIgAsS'),
          'https://lh3.googleusercontent.com/d/12rFxs_9xf4Gsi9j7FCA7aW8N7fYIgAsS');
      expect(driveDirectUrl('https://aknzone-afk.github.io/akn-zone-data/app/model/5938.jpg'), isNull);
      expect(driveDirectUrl('https://drive.google.com/thumbnail?id=../../x&sz=w600'), isNull);
      expect(driveDirectUrl('not a url at all'), isNull);
      expect(photoFetchOrder(drive), [direct, drive, direct]);
      expect(photoFetchOrder('https://example.com/a.jpg'), ['https://example.com/a.jpg', 'https://example.com/a.jpg']);
    });

    test('first address good: one request, no Drive front door', () async {
      final f = _FakeService({direct: [200]});
      final r = await PatientFileService(f).get(drive);
      expect(r.statusCode, 200);
      expect(f.asked, [direct]);
    });

    test('image host answers 504: Drive is tried next and wins', () async {
      final f = _FakeService({direct: [504], drive: [200]});
      final r = await PatientFileService(f).get(drive);
      expect(r.statusCode, 200);
      expect(f.asked, [direct, drive]);
    });

    test('a dropped connection is retried too', () async {
      final f = _FakeService({
        direct: [const FormatException('Connection closed before full header was received'), 200],
        drive: [429],
      });
      final r = await PatientFileService(f).get(drive);
      expect(r.statusCode, 200);
      expect(f.asked, [direct, drive, direct]);
    });

    test('everything refused: the last answer goes back (the cache manager reports it as before)', () async {
      final f = _FakeService({direct: [503], drive: [429]});
      final r = await PatientFileService(f).get(drive);
      expect(r.statusCode, 503);
      expect(f.asked, [direct, drive, direct]);
    });

    test('everything throws: the error is passed on', () async {
      final f = _FakeService({
        direct: [const FormatException('reset')],
        drive: [const FormatException('reset')],
      });
      await expectLater(PatientFileService(f).get(drive), throwsA(isA<FormatException>()));
      expect(f.asked.length, 3);
    });

    test('a photo that is gone (404) is not asked for three times', () async {
      final f = _FakeService({direct: [404]});
      final r = await PatientFileService(f).get(drive);
      expect(r.statusCode, 404);
      expect(f.asked, [direct]);
    });

    test('304 (still the same version) counts as an answer', () async {
      final f = _FakeService({direct: [304]});
      expect((await PatientFileService(f).get(drive)).statusCode, 304);
      expect(f.asked, [direct]);
    });
  });

  group('data backups', () {
    test('three copies, our own cloud first', () {
      final u = Uri.parse('https://aknzone-afk.github.io/akn-zone-data/app/prices.json?t=123');
      expect(dataMirrorUrls(u), [
        'https://asia-south2-akn-chat-a7dd8.cloudfunctions.net/appData?p=app%2Fprices.json',
        'https://raw.githubusercontent.com/aknzone-afk/akn-zone-data/main/app/prices.json',
        'https://cdn.statically.io/gh/aknzone-afk/akn-zone-data@main/app/prices.json',
      ]);
      expect(dataMirrorUrl(u), startsWith('https://asia-south2-akn-chat-a7dd8.cloudfunctions.net/appData'));
    });

    test('files outside app/ skip the cloud copy; other hosts have no backup', () {
      expect(dataMirrorUrls(Uri.parse('https://aknzone-afk.github.io/akn-zone-data/privacy.html')), [
        'https://raw.githubusercontent.com/aknzone-afk/akn-zone-data/main/privacy.html',
        'https://cdn.statically.io/gh/aknzone-afk/akn-zone-data@main/privacy.html',
      ]);
      expect(dataMirrorUrls(Uri.parse('https://example.com/akn-zone-data/app/x.json')), isEmpty);
      expect(dataMirrorUrl(Uri.parse('https://example.com/x')), isNull);
    });
  });
}
