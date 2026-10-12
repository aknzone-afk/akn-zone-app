import 'dart:io';

import 'package:dio/dio.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'chat_service.dart';

/// Real push (owner 11-Oct-2026): when the shop sends the bill or replies,
/// the customer's phone rings even with the app closed. Firebase Cloud
/// Messaging (free) in the AKN Chat Firebase project; the cloud sends to the
/// device tokens registered here for this phone's customer mobiles.
class PushService {
  static const _cloud = 'https://asia-south1-akn-chat-a7dd8.cloudfunctions.net';
  static const _kSent = 'push_registered_v1';

  /// Bumped when a push arrives while the app is open → chat bubble re-checks.
  static final ValueNotifier<int> tick = ValueNotifier(0);
  static bool _ready = false;

  static FirebaseOptions get _options => Platform.isIOS
      ? const FirebaseOptions(
          apiKey: 'AIzaSyAxhdqiCBOmFltULEA3ZgB-dtuvaoGBePc',
          appId: '1:525747821627:ios:3fcec35ed6fb3db395d01e',
          messagingSenderId: '525747821627',
          projectId: 'akn-chat-a7dd8',
          storageBucket: 'akn-chat-a7dd8.firebasestorage.app',
          iosBundleId: 'com.bbsynthetics.catalog',
        )
      : const FirebaseOptions(
          apiKey: 'AIzaSyAlgcvy486z4PspfQQZRIUOa8yR3YpWTYI',
          appId: '1:525747821627:android:b87db67ed7ee231795d01e',
          messagingSenderId: '525747821627',
          projectId: 'akn-chat-a7dd8',
          storageBucket: 'akn-chat-a7dd8.firebasestorage.app',
        );

  /// Call once at start. [onOpenChat] runs when a push is tapped.
  static Future<void> init(void Function() onOpenChat) async {
    if (_ready) return;
    try {
      await Firebase.initializeApp(options: _options);
      final fm = FirebaseMessaging.instance;
      await fm.setForegroundNotificationPresentationOptions(alert: true, badge: true, sound: true);
      FirebaseMessaging.onMessage.listen((_) => tick.value++);
      FirebaseMessaging.onMessageOpenedApp.listen((_) => onOpenChat());
      final first = await fm.getInitialMessage();
      if (first != null) onOpenChat();
      fm.onTokenRefresh.listen((_) {
        _lastKey = null;
        _stale = true;
      });
      _ready = true;
    } catch (e) {
      debugPrint('push init: $e');
    }
  }

  static String? _lastKey;
  static bool _stale = false; // the token changed since the last post

  /// Tells the cloud which customer mobiles this phone follows. Cheap to call
  /// often: only posts when the token or the mobiles changed.
  static Future<void> register(SharedPreferences prefs, Dio dio) async {
    if (!_ready) return;
    final mobiles = ChatService.mobiles(prefs);
    if (mobiles.isEmpty) return;
    // Same numbers as the last successful post and no new token → nothing to
    // do (this runs with every 30-s chat poll).
    final last = _lastKey ?? prefs.getString(_kSent);
    if (!_stale && last != null && last.endsWith('|${mobiles.join(',')}')) {
      _lastKey = last;
      return;
    }
    try {
      final fm = FirebaseMessaging.instance;
      final perm = await fm.requestPermission(alert: true, badge: true, sound: true);
      if (perm.authorizationStatus == AuthorizationStatus.denied) return;
      // iPhone: the Apple push address — the cloud sends straight to Apple.
      final apns = Platform.isIOS ? await fm.getAPNSToken() : null;
      if (Platform.isIOS && apns == null) return; // not ready yet; next time
      String? token;
      try {
        token = await fm.getToken();
      } catch (_) {}
      token ??= apns; // FCM may refuse without Firebase's APNs setup; Apple's address is enough
      if (token == null) return;
      final key = '$token|${apns ?? ''}|${mobiles.join(',')}';
      if (key == _lastKey || key == prefs.getString(_kSent)) {
        _lastKey = key;
        return;
      }
      final r = await dio.post<dynamic>('$_cloud/registerPush',
          data: {
            'token': token,
            if (apns != null) 'apns': apns,
            'mobiles': mobiles,
            'platform': Platform.isIOS ? 'ios' : 'android'
          },
          options: Options(
              headers: {'x-app-key': 'akn-zone-app-2026'},
              contentType: Headers.jsonContentType,
              receiveTimeout: const Duration(seconds: 15)));
      if (r.statusCode == 200) {
        _lastKey = key;
        _stale = false;
        await prefs.setString(_kSent, key);
      }
    } catch (e) {
      debugPrint('push register: $e');
    }
  }
}
