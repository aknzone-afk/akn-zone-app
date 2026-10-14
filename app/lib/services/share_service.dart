import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/photo.dart';

/// One photo + the markup PNG bytes produced for it (null if user skipped markup).
class ShareItem {
  final Photo photo;
  final Uint8List bytes;
  ShareItem({required this.photo, required this.bytes});
}

class ShareService {
  /// Dump bytes to a temp file the OS can hand to other apps via content://.
  /// Cleans up old shares older than 1 hour on every call to avoid bloat.
  Future<List<XFile>> writeShareFiles(List<ShareItem> items) async {
    final root = await getTemporaryDirectory();
    final dir = Directory(p.join(root.path, 'catalog_share'));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    _cleanupOld(dir, maxAge: const Duration(hours: 1));

    final ts = DateTime.now().millisecondsSinceEpoch;
    final files = <XFile>[];
    for (var i = 0; i < items.length; i++) {
      final base = _sanitize(items[i].photo.filename);
      final stem = p.basenameWithoutExtension(base);
      final outPath = p.join(dir.path, '${ts}_${i}_$stem.png');
      final file = File(outPath);
      await file.writeAsBytes(items[i].bytes, flush: true);
      files.add(XFile(outPath, name: '$stem.png', mimeType: 'image/png'));
    }
    return files;
  }

  /// Share to WhatsApp specifically when possible; falls back to system sheet.
  Future<void> shareToWhatsApp({
    required List<ShareItem> items,
    String? message,
    String? phoneNumber,
  }) async {
    if (items.isEmpty) return;
    final files = await writeShareFiles(items);

    // share_plus on Android shows a target picker that includes WhatsApp.
    // We don't strictly need to deep-link if there's nothing to send to a
    // specific contact — the picker handles that. Caller may pass [phoneNumber]
    // to deep-link to a specific chat (text only, image goes via the sheet).
    if (phoneNumber != null &&
        phoneNumber.isNotEmpty &&
        (message ?? '').isNotEmpty) {
      final waUrl = Uri.parse(
        'https://wa.me/$phoneNumber?text=${Uri.encodeComponent(message!)}',
      );
      // Fire-and-forget — WhatsApp will open the chat; user can paste the
      // images from the share sheet shown next.
      // ignore: discarded_futures
      launchUrl(waUrl, mode: LaunchMode.externalApplication);
    }

    await Share.shareXFiles(
      files,
      text: message,
      subject: 'B.B Synthetics catalog',
      // iOS requires a non-zero anchor rect; this path has no widget context,
      // so use a minimal valid rect (this share path is currently unused).
      sharePositionOrigin: const Rect.fromLTWH(0, 0, 1, 1),
    );
  }

  static String _sanitize(String filename) {
    return filename.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
  }

  static void _cleanupOld(Directory dir, {required Duration maxAge}) {
    final cutoff = DateTime.now().subtract(maxAge);
    try {
      for (final f in dir.listSync()) {
        try {
          final stat = f.statSync();
          if (stat.modified.isBefore(cutoff)) {
            f.deleteSync(recursive: true);
          }
        } catch (_) {/* ignore */}
      }
    } catch (_) {/* ignore */}
  }
}
