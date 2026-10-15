import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

/// Owner 15-Oct: the shop's location, ONCE, at sign-up / first login — so the
/// shop can see where the customer is. Optional: saying no never blocks.
class ShopLocation {
  static Map<String, dynamic> _of(Position p) =>
      {'lat': p.latitude, 'lng': p.longitude, 'acc': p.accuracy.round()};

  static Future<Map<String, dynamic>?> ask(BuildContext context) async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return null;
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        if (!context.mounted) return null;
        // Apple: a note before the system question — one button only.
        await showDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (c) => AlertDialog(
            title: const Text('Your shop location'),
            content: const Text(
                'Next, your phone will ask to share your location. It is used only once, to verify your shop '
                'and approve your account faster. You can say no and still continue.'),
            actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('CONTINUE'))],
          ),
        );
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) return null;
      try {
        final p = await Geolocator.getCurrentPosition(
            locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, timeLimit: Duration(seconds: 12)));
        return _of(p);
      } catch (_) {
        final last = await Geolocator.getLastKnownPosition();
        return last == null ? null : _of(last);
      }
    } catch (_) {
      return null;
    }
  }
}
