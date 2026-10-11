// Unit tests for the multi-select state that powers the catalog grid,
// the search "Select all" bar, and "Send to cart".
//
// (Replaces the stale Flutter counter template that referenced a non-existent
// `MyApp` and would have failed the suite.)

import 'package:catalog_app/providers/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // HapticFeedback (fired by SelectionNotifier) needs the test binding's
  // mocked platform channels so it stays a no-op in tests.
  TestWidgetsFlutterBinding.ensureInitialized();

  group('selectionProvider', () {
    test('selectAll selects every id', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      c.read(selectionProvider.notifier).selectAll(['a', 'b', 'c']);
      expect(c.read(selectionProvider), {'a', 'b', 'c'});
    });

    test('toggle adds then removes the same id', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      c.read(selectionProvider.notifier).toggle('x');
      expect(c.read(selectionProvider), {'x'});
      c.read(selectionProvider.notifier).toggle('x');
      expect(c.read(selectionProvider), isEmpty);
    });

    test('clear empties the selection (double-tap behaviour)', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      c.read(selectionProvider.notifier).selectAll(['a', 'b']);
      c.read(selectionProvider.notifier).clear();
      expect(c.read(selectionProvider), isEmpty);
    });

    test('selectAll replaces any existing selection', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      c.read(selectionProvider.notifier).selectAll(['a', 'b']);
      c.read(selectionProvider.notifier).selectAll(['c']);
      expect(c.read(selectionProvider), {'c'});
    });
  });
}
