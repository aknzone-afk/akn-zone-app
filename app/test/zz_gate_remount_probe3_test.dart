// TEMPORARY audit probe 3 — notification deep link pushed while the gate is
// still on _Gate.loading (Router not mounted). Mirrors main.dart:62-65 + 76.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

final ValueNotifier<bool> allowed =
    ValueNotifier<bool>(false); // starts loading

final router = GoRouter(
  routes: [
    GoRoute(path: '/', builder: (_, __) => const Scaffold(body: Text('HOME'))),
    GoRoute(
      path: '/folder/:path',
      builder: (_, s) => Scaffold(
          body:
              Text('FOLDER ${Uri.decodeComponent(s.pathParameters["path"]!)}')),
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
    allowed.addListener(_c);
  }

  void _c() => setState(() {});
  @override
  void dispose() {
    allowed.removeListener(_c);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => allowed.value
      ? widget.child
      : const Scaffold(body: Center(child: CircularProgressIndicator()));
}

void main() {
  testWidgets('cold launch from notification while gate is loading', (t) async {
    await t.pumpWidget(MaterialApp.router(
      routerConfig: router,
      builder: (c, child) => Gate(child: child ?? const SizedBox.shrink()),
    ));
    // main.dart: post-frame callback after runApp
    WidgetsBinding.instance
        .addPostFrameCallback((_) => router.push('/folder/DAILY%20UPDATE'));
    await t.pump();
    await t.pump();
    debugPrint(
        'PROBE3: spinner? ${find.byType(CircularProgressIndicator).evaluate().length}');

    // gate finishes _resolve -> allowed -> Router mounts for the first time
    allowed.value = true;
    await t.pumpAndSettle();
    debugPrint('PROBE3: exception = ${t.takeException()}');
    debugPrint(
        'PROBE3: FOLDER shown? ${find.textContaining("FOLDER").evaluate().length}');
    debugPrint(
        'PROBE3: matches = ${router.routerDelegate.currentConfiguration.matches.map((m) => m.runtimeType).toList()}');
    debugPrint('PROBE3: canPop = ${router.routerDelegate.canPop()}');

    // user presses the system back button
    final popped = await router.routerDelegate.popRoute();
    await t.pumpAndSettle();
    debugPrint('PROBE3: popRoute handled = $popped');
    debugPrint(
        'PROBE3: after back -> HOME? ${find.text("HOME").evaluate().length} '
        'FOLDER? ${find.textContaining("FOLDER").evaluate().length}');
    debugPrint(
        'PROBE3: matches after back = ${router.routerDelegate.currentConfiguration.matches.length}');
  });
}
