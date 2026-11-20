import 'package:image_picker/image_picker.dart';

bool _picking = false;

/// Opens the phone's gallery for one picture or several (payment screenshots).
///
/// 20-Nov: a second tap while the gallery was still opening threw
/// "Image picker is already active", and a refused photo permission or a
/// broken gallery app threw straight into the screen. Now the second tap is
/// ignored and any failure simply gives an empty list — the customer stays
/// where they were and can tap again.
Future<List<XFile>> pickImagesSafely({bool multi = true}) async {
  if (_picking) return const [];
  _picking = true;
  try {
    if (multi) {
      return await ImagePicker().pickMultiImage(maxWidth: 1800, imageQuality: 85, limit: 10);
    }
    final x = await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 1800, imageQuality: 85);
    return x == null ? const [] : [x];
  } catch (_) {
    return const [];
  } finally {
    _picking = false;
  }
}
