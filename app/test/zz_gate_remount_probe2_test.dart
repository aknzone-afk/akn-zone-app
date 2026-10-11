// TEMPORARY audit probe 2 — state loss on gate remount, and recoverability.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

final ValueNotifier<bool> allowed = ValueNotifier<bool>(true);
int folderStateInits = 0;

class FolderProbe extends StatefulWidget {
  final String path;
  const FolderProbe(this.path, {super.key});
  @override
  State<FolderProbe> createState() => _FolderProbeState();
}

class _FolderProbeState extends State<FolderProbe> {
  int taps = 0; // stands in for scroll offset / local UI state
  @override
  void initState() {
    super.initState();
    folderStateInits++;
  }

  @override
  Widget build(BuildContext c) => Scaffold(
        body: Center(
          child: TextButton(
            onPressed: () => setState(() => taps++),
            child: Text('folder ${widget.path} taps=$taps'),
          ),
        ),
      );
}

final router = GoRouter(
  routes: [
    GoRoute(path: '/', builder: (_, __) => const Scaffold(body: Text('home'))),
    GoRoute(
      path: '/folder/:path',
      builder: (_, s) =>
          FolderProbe(Uri.decodeComponent(s.pathParameters['path']!)),
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
  testWidgets('folder route + local state across gate flip', (t) async {
    await t.pumpWidget(MaterialApp.router(
      routerConfig: router,
      builder: (c, child) => Gate(child: child ?? const SizedBox.shrink()),
    ));
    await t.pumpAndSettle();

    router.push('/folder/BANARASI');
    await t.pumpAndSettle();
    await t.tap(find.byType(TextButton));
    await t.pumpAndSettle();
    await t.pump(const Duration(milliseconds: 50));
    debugPrint(
        'PROBE2: before = ${find.textContaining("folder").evaluate().isEmpty ? "?" : (find.textContaining("folder").evaluate().first.widget as Text).data}');
    debugPrint('PROBE2: State inits so far = $folderStateInits');

    allowed.value = false; // resume -> _Gate.loading
    await t.pump();
    allowed.value = true; // _resolve done -> _Gate.allowed
    await t.pump();
    await t.pumpAndSettle();

    debugPrint('PROBE2: exception = ${t.takeException()}');
    final f = find.textContaining('folder');
    debugPrint(
        'PROBE2: after  = ${f.evaluate().isEmpty ? "GONE" : (f.evaluate().first.widget as Text).data}');
    debugPrint('PROBE2: at home? ${find.text('home').evaluate().length}');
    debugPrint('PROBE2: State inits total = $folderStateInits');
  });
}
