// TEMPORARY probe (not committed): what does BACK do after gate flips, with and without the safe parser,
// after a good and after a bad start?
import 'package:catalog_app/app.dart' show SafeRouteParser;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

GoRouter _router() => GoRouter(
      errorBuilder: (_, __) => const Scaffold(body: Text('HOME')),
      routes: [
        GoRoute(path: '/', builder: (_, __) => const Scaffold(body: Text('HOME'))),
        GoRoute(path: '/chat', builder: (_, __) => const Scaffold(body: Text('CHAT'))),
        GoRoute(path: '/daily', builder: (_, __) => const Scaffold(body: Text('DAILY'))),
      ],
    );

RouterConfig<RouteMatchList> _safe(GoRouter r) => RouterConfig<RouteMatchList>(
      routeInformationProvider: r.routeInformationProvider,
      routeInformationParser: SafeRouteParser(r.routeInformationParser),
      routerDelegate: r.routerDelegate,
      backButtonDispatcher: r.backButtonDispatcher,
    );

Future<void> _run(WidgetTester t, {required bool safe, required String start, required int flips}) async {
  t.binding.platformDispatcher.defaultRouteNameTestValue = start;
  addTearDown(t.binding.platformDispatcher.clearDefaultRouteNameTestValue);
  final r = _router();
  final RouterConfig<RouteMatchList> cfg = safe ? _safe(r) : r;
  final allowed = ValueNotifier<bool>(true);
  await t.pumpWidget(MaterialApp.router(
    routerConfig: cfg,
    builder: (_, child) => ValueListenableBuilder<bool>(
        valueListenable: allowed,
        builder: (_, ok, __) => ok ? child! : const Center(child: CircularProgressIndicator())),
  ));
  await t.pumpAndSettle();
  String m() => r.routerDelegate.currentConfiguration.matches.map((x) => '${x.runtimeType}:${x.matchedLocation}').toList().toString();
  debugPrint('PROBE safe=$safe start=$start | after start: ${m()} uri=${r.routerDelegate.currentConfiguration.uri} ex=${t.takeException()}');
  for (var i = 0; i < flips; i++) {
    allowed.value = false;
    await t.pump();
    allowed.value = true;
    await t.pumpAndSettle();
    debugPrint('PROBE   flip ${i + 1}: ${m()} uri=${r.routerDelegate.currentConfiguration.uri} ex=${t.takeException()} provider=${r.routeInformationProvider.value.uri} state=${r.routeInformationProvider.value.state.runtimeType}');
  }
  r.push('/chat');
  await t.pumpAndSettle();
  debugPrint('PROBE   after push: ${m()} chat=${find.text('CHAT').evaluate().length} ex=${t.takeException()}');
  Object? err;
  try {
    await t.binding.handlePopRoute();
  } catch (e) {
    err = e;
  }
  await t.pumpAndSettle();
  debugPrint('PROBE   after BACK: ${m()} home=${find.text('HOME').evaluate().length} err=$err ex=${t.takeException()}');
}

void main() {
  testWidgets('plain, good start, 0 flips', (t) => _run(t, safe: false, start: '/', flips: 0));
  testWidgets('plain, good start, 2 flips', (t) => _run(t, safe: false, start: '/', flips: 2));
  testWidgets('safe, good start, 0 flips', (t) => _run(t, safe: true, start: '/', flips: 0));
  testWidgets('safe, good start, 2 flips', (t) => _run(t, safe: true, start: '/', flips: 2));
  testWidgets('safe, bad start, 0 flips', (t) => _run(t, safe: true, start: 'daily', flips: 0));
  testWidgets('safe, bad start, 2 flips', (t) => _run(t, safe: true, start: 'daily', flips: 2));
}
