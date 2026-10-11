import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Persists user-edited copies of photos (markup over the original). Writes
/// PNG bytes to a private `edits/` folder in the app's storage and exposes
/// helpers to look up the path / check existence for a given Drive file id.
///
/// Used by the markup screen to "save into cart" — the cart view then shows
/// the edited version instead of the original Drive thumbnail.
class EditService {
  Directory? _dir;

  Future<Directory> _editsDir() async {
    if (_dir != null) return _dir!;
    final base = await getApplicationSupportDirectory();
    final dir = Directory(p.join(base.path, 'edits'));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    _dir = dir;
    return dir;
  }

  String _fileNameFor(String photoId) {
    // Sanitize photoId for use as a filename.
    return '${_safe(photoId)}.png';
  }

  String _safe(String photoId) =>
      photoId.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');

  /// The un-marked base image the strokes are drawn over (kept so re-opening
  /// an edit can restore editable strokes for Undo).
  Future<void> saveBase(String photoId, Uint8List bytes) async {
    final dir = await _editsDir();
    final f = File(p.join(dir.path, '${_safe(photoId)}.base'));
    await f.writeAsBytes(bytes, flush: true);
  }

  Future<Uint8List?> readBase(String photoId) async {
    final dir = await _editsDir();
    final f = File(p.join(dir.path, '${_safe(photoId)}.base'));
    if (!f.existsSync()) return null;
    return f.readAsBytes();
  }

  /// The editable stroke list (JSON) so Undo keeps working after re-opening.
  Future<void> saveStrokes(String photoId, String json) async {
    final dir = await _editsDir();
    final f = File(p.join(dir.path, '${_safe(photoId)}.strokes.json'));
    await f.writeAsString(json, flush: true);
  }

  Future<String?> readStrokes(String photoId) async {
    final dir = await _editsDir();
    final f = File(p.join(dir.path, '${_safe(photoId)}.strokes.json'));
    if (!f.existsSync()) return null;
    return f.readAsString();
  }

  /// Saves [bytes] for [photoId]. Overwrites any previous edit.
  Future<File> save(String photoId, Uint8List bytes) async {
    final dir = await _editsDir();
    final f = File(p.join(dir.path, _fileNameFor(photoId)));
    await f.writeAsBytes(bytes, flush: true);
    return f;
  }

  /// Returns the on-disk file for [photoId] (may or may not exist).
  Future<File> pathFor(String photoId) async {
    final dir = await _editsDir();
    return File(p.join(dir.path, _fileNameFor(photoId)));
  }

  Future<bool> exists(String photoId) async {
    final f = await pathFor(photoId);
    return f.existsSync();
  }

  /// Drive version of the photo the edit was drawn on, when known.
  Future<void> saveVersion(String photoId, String version) async {
    final dir = await _editsDir();
    await File(p.join(dir.path, '${_safe(photoId)}.version'))
        .writeAsString(version, flush: true);
  }

  Future<String?> readVersion(String photoId) async {
    final dir = await _editsDir();
    final f = File(p.join(dir.path, '${_safe(photoId)}.version'));
    if (!f.existsSync()) return null;
    final v = (await f.readAsString()).trim();
    return v.isEmpty ? null : v;
  }

  /// The photo was replaced on Drive: delete the baked edit and its old base
  /// picture but keep the strokes, so re-opening the editor redraws them on
  /// the new photo. Returns true if there was an edit to drop.
  Future<bool> dropRendered(String photoId) async {
    final dir = await _editsDir();
    final png = File(p.join(dir.path, _fileNameFor(photoId)));
    final had = png.existsSync();
    for (final name in [
      _fileNameFor(photoId),
      '${_safe(photoId)}.base',
      '${_safe(photoId)}.version',
    ]) {
      final f = File(p.join(dir.path, name));
      if (f.existsSync()) {
        try {
          await f.delete();
        } catch (_) {}
      }
    }
    return had;
  }

  Future<void> remove(String photoId) async {
    final dir = await _editsDir();
    for (final name in [
      _fileNameFor(photoId),
      '${_safe(photoId)}.base',
      '${_safe(photoId)}.strokes.json',
      '${_safe(photoId)}.version',
    ]) {
      final f = File(p.join(dir.path, name));
      if (f.existsSync()) {
        try {
          await f.delete();
        } catch (_) {/* ignore */}
      }
    }
  }

  /// Reads bytes for [photoId] if an edit exists, else null.
  Future<Uint8List?> read(String photoId) async {
    final f = await pathFor(photoId);
    if (!f.existsSync()) return null;
    return f.readAsBytes();
  }

  /// Returns the set of photo ids that have an on-disk edit. Used to populate
  /// the editsProvider on app start.
  Future<Set<String>> listAll() async {
    final dir = await _editsDir();
    if (!dir.existsSync()) return const <String>{};
    final out = <String>{};
    for (final entry in dir.listSync()) {
      if (entry is File && entry.path.endsWith('.png')) {
        final stem = p.basenameWithoutExtension(entry.path);
        out.add(stem);
      }
    }
    return out;
  }
}
