import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/photo.dart';

/// What a price label should show for a photo right now.
enum PriceDisplay {
  /// The stored price, confirmed to come from the photo currently on Drive.
  show,

  /// Still confirming against Drive (only briefly, right after opening).
  checking,

  /// The photo changed on Drive; its new price is being read.
  updating,

  /// No price to show.
  none,
}

/// The Drive version seen for each photo in the current check round. A price
/// is shown only when it was read from that version, so a customer never sees
/// the rate of a photo the owner has since replaced.
class PriceCheckState {
  const PriceCheckState({this.live = const {}, this.trustCache = false, this.round = 0});

  final Map<String, String> live;

  /// Show stored prices of photos not checked yet — when offline or between
  /// rounds after the first successful one.
  final bool trustCache;

  /// Incremented on each startRound so widgets can re-register priorities.
  final int round;
}

PriceDisplay priceDisplayFor(Photo photo, PriceCheckState check) {
  if (photo.priceFromFolder) return PriceDisplay.show;
  final live = check.live[photo.id];
  final changed = live != null && live != photo.driveVersion;
  if (photo.ocrState != OcrState.done || changed) {
    // A photo never priced has nothing old to hide.
    return photo.price == null && !changed
        ? PriceDisplay.none
        : PriceDisplay.updating;
  }
  if (photo.price == null) return PriceDisplay.none;
  if (live != null || check.trustCache) return PriceDisplay.show;
  return PriceDisplay.checking;
}

/// Label text for a price in [display] state.
String priceLabel(Photo photo, PriceDisplay display) =>
    display == PriceDisplay.show ? '₹${photo.price}' : '₹ ···';

class PriceCheckNotifier extends StateNotifier<PriceCheckState> {
  PriceCheckNotifier() : super(const PriceCheckState());

  final Map<String, String> _batch = {};
  Timer? _flush;

  /// A new round: nothing confirmed yet, so unconfirmed prices are hidden.
  void startRound() {
    _flush?.cancel();
    _flush = null;
    _batch.clear();
    state = PriceCheckState(trustCache: false, round: state.round + 1);
  }

  void record(String photoId, String version) {
    _batch[photoId] = version;
    _flush ??= Timer(const Duration(milliseconds: 250), _apply);
  }

  void _apply() {
    _flush = null;
    if (_batch.isEmpty || !mounted) return;
    state = PriceCheckState(
      live: {...state.live, ..._batch},
      trustCache: state.trustCache,
    );
    _batch.clear();
  }

  /// Stop hiding unconfirmed prices (round over, offline, or taking long).
  void trust() {
    if (!mounted) return;
    _flush?.cancel();
    _apply();
    if (!state.trustCache) {
      state = PriceCheckState(live: state.live, trustCache: true, round: state.round);
    }
  }

  /// Re-hide unconfirmed prices (network came back after offline trust).
  void distrust() {
    if (!mounted || !state.trustCache) return;
    state = PriceCheckState(live: state.live, trustCache: false, round: state.round);
  }
}
