import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Hindi / English for the customer screens (owner, 11-Oct-2026: "even a
/// customer who knows nothing must be able to order"). `t('Done', 'हो गया')`
/// picks the text for the chosen language; the whole app rebuilds on change.
final ValueNotifier<bool> hindiNotifier = ValueNotifier<bool>(false);
const _kLangKey = 'lang_v1';

bool get isHindi => hindiNotifier.value;
String t(String en, String hi) => hindiNotifier.value ? hi : en;

/// Null until the customer has picked a language once.
String? savedLanguage(SharedPreferences p) => p.getString(_kLangKey);

/// Owner, 11-Oct-2026: English only for now (Hindi text kept for later).
void loadLanguage(SharedPreferences p) {
  hindiNotifier.value = false;
}

Future<void> setHindi(SharedPreferences p, bool hindi) async {
  hindiNotifier.value = hindi;
  await p.setString(_kLangKey, hindi ? 'hi' : 'en');
}
