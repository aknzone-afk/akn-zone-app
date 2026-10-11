import 'package:catalog_app/services/picks_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('sets + colours', () {
    const s = PickState(sets: 2, marks: [PickMark(.1, .1, 3), PickMark(.5, .5, 1)]);
    expect(s.total(7), 18); // 2 sets × 7 colours + 4
    expect(s.summary(7), '2 SET (14 PCS) + 4 SELECTED PCS = 18 SAREES');
    expect(s.total(null), isNull); // sets but count unknown
    expect(const PickState(marks: [PickMark(.1, .1, 2)]).total(null), 2);
    expect(const PickState().isEmpty, isTrue);
  });
  test('cross = colour not wanted in a set', () {
    const s = PickState(sets: 1, marks: [PickMark(.2, .2, -1), PickMark(.5, .5, 2)]);
    expect(s.total(7), 8); // 1 set of 6 colours + 2
    expect(s.summary(7), '1 SET (6 PCS) + 2 SELECTED PCS = 8 SAREES  ·  1 ✕ NOT WANTED');
    expect(const PickState(marks: [PickMark(.2, .2, -1)]).isEmpty, isTrue);
  });
}
