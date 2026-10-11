// TEMPORARY independent audit probe (refutation attempt). Delete after run.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

enum G { loading, allowed }

final ValueNotifier<G> gate = ValueNotifier<G>(G.allowed);

Object? lastPhotoExtraRuntimeType;

GoRouter makeRouter() => GoRouter(
      routes: [
        GoRoute(
            path: '/', builder: (_, __) => const Scaffold(body: Text('HOME'))),
        GoRoute(
          path: '/photo/:id',
          builder: (_, state) {
            lastPhotoExtraRuntimeType = state.extra?.runtimeType;
            final id = Uri.decodeComponent(state.pathParameters['id']!);
            // VERBATIM lib/app.dart:35
            final ids = (state.extra as List<String>?) ?? [id];
            return Scaffold(body: Text('PHOTO $id n=${ids.length}'));
          },
        ),
        GoRoute(
          path: '/markup',
          builder: (_, state) {
            // VERBATIM lib/app.dart:42
            final ids = (state.extra as List<String>?) ?? const <String>[];
            return Scaffold(body: Text('MARKUP n=${ids.length}'));
          },
        ),
      ],
    );

// Mirrors _AuthGateState.build(): _Gate.loading returns a spinner Scaffold and
// does NOT build widget.child (access_control.dart:106-120).
class Gate extends StatefulWidget {
  final Widget child;
  const Gate({super.key, required this.child});
  @override
  State<Gate> createState() => _GateState();
}

class _GateState extends State<Gate> {
  @override
  void initState() {
    super.initState();
    gate.addListener(_c);
  }

  void _c() => setState(() {});
  @override
  void dispose() {
    gate.removeListener(_c);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => switch (gate.value) {
        G.loading =>
          const Scaffold(body: Center(child: CircularProgressIndicator())),
        G.allowed => widget.child,
      };
}

void main() {
  setUp(() {
    gate.value = G.allowed;
    lastPhotoExtraRuntimeType = null;
  });

  testWidgets('A: builder child identity + provider state after push',
      (t) async {
    final router = makeRouter();
    Widget? seenChild;
    await t.pumpWidget(MaterialApp.router(
      routerConfig: router,
      builder: (c, child) {
        seenChild = child;
        return Gate(child: child ?? const SizedBox.shrink());
      },
    ));
    await t.pumpAndSettle();
    debugPrint('A: MaterialApp.router builder child = ${seenChild.runtimeType}'
        ' / is Router = ${seenChild is Router}');

    router.push('/photo/abc', extra: <String>['a', 'b', 'c']);
    await t.pumpAndSettle();
    await t.pump(const Duration(milliseconds: 50));

    final v = router.routeInformationProvider.value;
    debugPrint('A: provider.value.uri   = ${v.uri}');
    debugPrint('A: provider.value.state = ${v.state.runtimeType}');
    debugPrint('A: state = ${v.state}');
  });

  testWidgets('C: production sequence — push, then gate loading→allowed',
      (t) async {
    final router = makeRouter();
    await t.pumpWidget(MaterialApp.router(
      routerConfig: router,
      builder: (c, child) => Gate(child: child ?? const SizedBox.shrink()),
    ));
    await t.pumpAndSettle();
    debugPrint('C: start HOME? ${find.text('HOME').evaluate().length}');

    // photo_grid.dart:62 — extra is List<String>
    router.push('/photo/abc', extra: <String>['a', 'b', 'c']);
    await t.pumpAndSettle();
    await t.pump(const Duration(milliseconds: 50));
    debugPrint('C: before background extra type = $lastPhotoExtraRuntimeType');
    debugPrint(
        'C: PHOTO n=3 shown? ${find.text('PHOTO abc n=3').evaluate().length}');

    // Resume: access_control.dart:50 -> _resolve() -> :58 setState(loading).
    gate.value = G.loading;
    await t.pump();
    debugPrint(
        'C: spinner=${find.byType(CircularProgressIndicator).evaluate().length}'
        ' Router mounted=${find.byType(Router).evaluate().length}');

    // _resolve resolves 'approved' -> _Gate.allowed -> Router remounts
    gate.value = G.allowed;
    await t.pump();
    await t.pump(const Duration(milliseconds: 50));

    final err = t.takeException();
    debugPrint('C: extra type after remount = $lastPhotoExtraRuntimeType');
    debugPrint('C: EXCEPTION = $err');
    debugPrint('C: PHOTO n=3? ${find.text('PHOTO abc n=3').evaluate().length}'
        ' PHOTO n=1? ${find.text('PHOTO abc n=1').evaluate().length}'
        ' HOME? ${find.text('HOME').evaluate().length}');

    // sticky? second resume cycle
    gate.value = G.loading;
    await t.pump();
    gate.value = G.allowed;
    await t.pump();
    await t.pump(const Duration(milliseconds: 50));
    debugPrint('C: 2nd cycle EXCEPTION = ${t.takeException()}');
  });

  testWidgets('C2: same but for /markup', (t) async {
    final router = makeRouter();
    await t.pumpWidget(MaterialApp.router(
      routerConfig: router,
      builder: (c, child) => Gate(child: child ?? const SizedBox.shrink()),
    ));
    await t.pumpAndSettle();
    router.push('/markup', extra: <String>['x']);
    await t.pumpAndSettle();
    await t.pump(const Duration(milliseconds: 50));
    debugPrint('C2: MARKUP n=1? ${find.text('MARKUP n=1').evaluate().length}');
    gate.value = G.loading;
    await t.pump();
    gate.value = G.allowed;
    await t.pump();
    await t.pump(const Duration(milliseconds: 50));
    debugPrint('C2: EXCEPTION = ${t.takeException()}');
    debugPrint('C2: MARKUP shown? '
        '${find.textContaining('MARKUP').evaluate().length}');
  });

  testWidgets('D: control — same flip while at HOME (extra == null)',
      (t) async {
    final router = makeRouter();
    await t.pumpWidget(MaterialApp.router(
      routerConfig: router,
      builder: (c, child) => Gate(child: child ?? const SizedBox.shrink()),
    ));
    await t.pumpAndSettle();
    await t.pump(const Duration(milliseconds: 50));
    gate.value = G.loading;
    await t.pump();
    gate.value = G.allowed;
    await t.pump();
    await t.pump(const Duration(milliseconds: 50));
    debugPrint('D: EXCEPTION = ${t.takeException()}');
    debugPrint('D: HOME? ${find.text('HOME').evaluate().length}');
  });

  testWidgets('F: does the fix (cast<String>()) survive the same sequence?',
      (t) async {
    final fixed = GoRouter(routes: [
      GoRoute(
          path: '/', builder: (_, __) => const Scaffold(body: Text('HOME'))),
      GoRoute(
        path: '/photo/:id',
        builder: (_, state) {
          final id = Uri.decodeComponent(state.pathParameters['id']!);
          final ids = (state.extra as List?)?.cast<String>() ?? [id];
          return Scaffold(body: Text('PHOTO $id n=${ids.length}'));
        },
      ),
    ]);
    await t.pumpWidget(MaterialApp.router(
      routerConfig: fixed,
      builder: (c, child) => Gate(child: child ?? const SizedBox.shrink()),
    ));
    await t.pumpAndSettle();
    fixed.push('/photo/abc', extra: <String>['a', 'b', 'c']);
    await t.pumpAndSettle();
    await t.pump(const Duration(milliseconds: 50));
    gate.value = G.loading;
    await t.pump();
    gate.value = G.allowed;
    await t.pump();
    await t.pump(const Duration(milliseconds: 50));
    debugPrint('F: EXCEPTION = ${t.takeException()}');
    debugPrint('F: PHOTO n=3? ${find.text('PHOTO abc n=3').evaluate().length}');
  });

  test('E: json round-trip of List<String>', () {
    final decoded = json.decoder.convert(json.encoder.convert(<String>['a']));
    debugPrint('E: decoded runtimeType = ${decoded.runtimeType}');
    try {
      decoded as List<String>?;
      debugPrint('E: cast SUCCEEDED');
    } catch (e) {
      debugPrint('E: cast THREW: $e');
    }
  });
}
