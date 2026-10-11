// TEMPORARY audit probe — reproduces the AuthGate teardown/remount cycle.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

final ValueNotifier<bool> allowed = ValueNotifier<bool>(true);

final router = GoRouter(
  routes: [
    GoRoute(path: '/', builder: (_, __) => const Text('home')),
    GoRoute(
      path: '/photo/:id',
      builder: (_, state) {
        final id = Uri.decodeComponent(state.pathParameters['id']!);
        // EXACT line from lib/app.dart:35
        final ids = (state.extra as List<String>?) ?? [id];
        return Text('photo $id n=${ids.length}');
      },
    ),
    GoRoute(
      path: '/markup',
      builder: (_, state) {
        // EXACT line from lib/app.dart:42
        final ids = (state.extra as List<String>?) ?? const <String>[];
        return Text('markup n=${ids.length}');
      },
    ),
  ],
);

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
    allowed.addListener(_onChange);
  }

  void _onChange() => setState(() {});

  @override
  void dispose() {
    allowed.removeListener(_onChange);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Mirrors _AuthGateState.build: non-allowed states DO NOT build widget.child
    if (!allowed.value) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return widget.child;
  }
}

void main() {
  testWidgets('deep route survives an AuthGate loading flip?', (t) async {
    await t.pumpWidget(MaterialApp.router(
      routerConfig: router,
      builder: (c, child) => Gate(child: child ?? const SizedBox.shrink()),
    ));
    await t.pumpAndSettle();
    expect(find.text('home'), findsOneWidget);

    // User taps a design in the grid (photo_grid.dart:62-64)
    router.push('/photo/abc', extra: <String>['a', 'b', 'c']);
    await t.pumpAndSettle();
    // let the post-frame route-information report run
    await t.pump(const Duration(milliseconds: 50));
    expect(find.text('photo abc n=3'), findsOneWidget);
    debugPrint('PROBE: deep route OK before backgrounding');

    // App is backgrounded (share to WhatsApp) and resumed ->
    // didChangeAppLifecycleState -> _resolve() -> setState(_Gate.loading)
    allowed.value = false;
    await t.pump();
    debugPrint('PROBE: gate showing spinner, Router unmounted');

    // _resolve finishes -> _Gate.allowed -> Router remounts
    allowed.value = true;
    await t.pump();
    await t.pump(const Duration(milliseconds: 50));

    final err = t.takeException();
    debugPrint('PROBE: exception after remount = $err');
    debugPrint(
        'PROBE: photo n=3 still there? ${find.text('photo abc n=3').evaluate().length}');
    debugPrint(
        'PROBE: fallback n=1 rendered? ${find.text('photo abc n=1').evaluate().length}');
    debugPrint('PROBE: back at home? ${find.text('home').evaluate().length}');
  });
}
