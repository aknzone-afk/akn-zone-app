import 'package:catalog_app/widgets/caps_text.dart';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:share_plus/share_plus.dart';

import '../models/photo.dart';
import 'drive_urls.dart';
import 'edit_service.dart';
import 'price_markup.dart';

enum WhatsAppFlavor { regular, business }

class WhatsAppShare {
  static const _packageRegular = 'com.whatsapp';
  static const _packageBusiness = 'com.whatsapp.w4b';
  static const _channel = MethodChannel('com.bbsynthetics.catalog_app/share');

  /// Probe the device for installed WhatsApp variants. Uses the existing
  /// native MethodChannel + the `<queries>` declarations in AndroidManifest
  /// so we don't need the QUERY_ALL_PACKAGES permission (which Google Play
  /// rejects for this use case).
  static Future<({bool regular, bool business})> detectInstalled() async {
    Future<bool> check(String pkg) async {
      try {
        final r = await _channel.invokeMethod<bool>(
          'isPackageInstalled',
          <String, dynamic>{'package': pkg},
        );
        return r ?? false;
      } catch (_) {
        return false;
      }
    }

    final r = await check(_packageRegular);
    final b = await check(_packageBusiness);
    return (regular: r, business: b);
  }

  /// Show a chooser when both apps are present.
  static Future<WhatsAppFlavor?> _chooseFlavor(BuildContext context) async {
    return showDialog<WhatsAppFlavor>(
      context: context,
      builder: (_) => SimpleDialog(
        title: const UText('Send via'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, WhatsAppFlavor.regular),
            child: const Row(children: [
              Icon(Icons.chat, color: Color(0xFF25D366)),
              SizedBox(width: 12),
              UText('WhatsApp'),
            ]),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, WhatsAppFlavor.business),
            child: const Row(children: [
              Icon(Icons.business_center, color: Color(0xFF1DAB61)),
              SizedBox(width: 12),
              UText('WhatsApp Business'),
            ]),
          ),
        ],
      ),
    );
  }

  /// End-to-end multi-photo share:
  ///   1. Resolve bytes for each photo (prefers edited PNG from EditService)
  ///   2. Detect installed WhatsApp variants
  ///   3. If both installed, ask the user
  ///   4. Direct-share to the chosen package via AndroidIntent
  ///   5. If only one installed, share to that one without asking
  ///   6. If neither, fall back to system share sheet
  static Future<void> shareDirectly({
    required BuildContext context,
    required List<Photo> photos,
    required EditService editService,
    required Dio dio,
    String? message,
    double markupPercent = 0,
    double gstPercent = 0,
    Map<String, int>? manualPrices,
    bool asPdf = false,
  }) async {
    final files = await _resolveFiles(
      photos: photos,
      editService: editService,
      dio: dio,
      markupPercent: markupPercent,
      gstPercent: gstPercent,
      manualPrices: manualPrices,
    );
    if (!context.mounted) return;
    if (files.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: UText('Nothing to share.')),
      );
      return;
    }

    // Combine every design into ONE PDF and share it via the system sheet
    // (the user then picks WhatsApp) — simpler + reliable for a document.
    if (asPdf) {
      final pdfFile = await _buildSinglePdf(files);
      if (!context.mounted) return;
      await Share.shareXFiles(
        [
          XFile(pdfFile.path,
              name: 'SAREE DESIGNS.pdf', mimeType: 'application/pdf')
        ],
        text: (message != null && message.isNotEmpty) ? message : null,
        sharePositionOrigin: _shareOrigin(context),
      );
      return;
    }

    final installed = await detectInstalled();
    if (!context.mounted) return;

    String? targetPackage;
    if (installed.regular && installed.business) {
      final pick = await _chooseFlavor(context);
      if (pick == null) return;
      targetPackage =
          pick == WhatsAppFlavor.regular ? _packageRegular : _packageBusiness;
    } else if (installed.regular) {
      targetPackage = _packageRegular;
    } else if (installed.business) {
      targetPackage = _packageBusiness;
    }

    if (targetPackage != null) {
      try {
        await _launchWhatsAppIntent(
          files: files,
          message: message,
          targetPackage: targetPackage,
        );
        return;
      } catch (_) {
        // Fall back to system share sheet if the direct intent failed.
      }
    }

    // Fallback — system share sheet. Only attach text if a non-empty message
    // was supplied (cart send passes null → images only, no caption).
    if (!context.mounted) return;
    await Share.shareXFiles(
      files
          .map((f) =>
              XFile(f.path, name: p.basename(f.path), mimeType: 'image/jpeg'))
          .toList(),
      text: (message != null && message.isNotEmpty) ? message : null,
      // iOS requires a non-zero anchor rect for the share-sheet popover.
      sharePositionOrigin: _shareOrigin(context),
    );
  }

  /// iOS demands a non-zero source rect for the share sheet (the popover anchor
  /// on iPad). Derive it from the calling widget; fall back to a 1×1 on-screen
  /// rect so the share never throws on iOS. Android ignores this.
  static Rect _shareOrigin(BuildContext context) {
    final box = context.findRenderObject() as RenderBox?;
    if (box != null && box.hasSize) {
      return box.localToGlobal(Offset.zero) & box.size;
    }
    final size = MediaQuery.maybeOf(context)?.size;
    if (size != null) {
      return Rect.fromCenter(
        center: Offset(size.width / 2, size.height - 24),
        width: 1,
        height: 1,
      );
    }
    return const Rect.fromLTWH(0, 0, 1, 1);
  }

  /// Write all the bytes we want to share into a private cache folder. The
  /// shared FileProvider exposes this folder as `content://…/cache/share/…`.
  ///
  /// Each photo is fetched + written in parallel (16-way worker pool) to keep
  /// big-cart shares quick. Downloads are 1280 px — wide enough for WhatsApp
  /// preview quality without quadrupling bytes-on-wire vs 2000 px.
  /// Renders every shared image into a single multi-page PDF (one design per
  /// page, fit to the page) and returns the file.
  static Future<File> _buildSinglePdf(List<File> images) async {
    final doc = pw.Document();
    for (final f in images) {
      var bytes = await f.readAsBytes();
      // Slim each page before embedding: cap at ~1080 px / q80. On a phone
      // screen that's visually identical, but the PDF lands at roughly half
      // the size — quicker to generate and to send on WhatsApp.
      try {
        final slim = await FlutterImageCompress.compressWithList(
          bytes,
          quality: 80,
          minWidth: 1080,
          minHeight: 1080,
          format: CompressFormat.jpeg,
        );
        if (slim.isNotEmpty) bytes = slim;
      } catch (_) {/* keep original bytes */}
      final img = pw.MemoryImage(bytes);
      // Size each page EXACTLY to the image so the PDF has no white margin or
      // border — every page is just the picture, edge to edge.
      doc.addPage(
        pw.Page(
          pageFormat: PdfPageFormat(
            (img.width ?? 1000).toDouble(),
            (img.height ?? 1000).toDouble(),
          ),
          margin: pw.EdgeInsets.zero,
          build: (ctx) => pw.Image(img, fit: pw.BoxFit.fill),
        ),
      );
    }
    final root = await getApplicationSupportDirectory();
    final dir = Directory(p.join(root.path, 'share'));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    // Named so the file shows as "SAREE DESIGNS.pdf" on WhatsApp.
    final out = File(p.join(dir.path, 'SAREE DESIGNS.pdf'));
    await out.writeAsBytes(await doc.save(), flush: true);
    return out;
  }

  /// Stamps a small, low-opacity "AKN" mark in the top-left corner of [bytes]
  /// so every shared design stays quietly attributable to the shop. It is
  /// deliberately subtle — barely noticeable unless you know to look for it.
  /// Best-effort: any failure returns the original bytes untouched so a share
  /// is never blocked.
  static Future<Uint8List> _stampWatermark(Uint8List bytes) async {
    if (bytes.isEmpty) return bytes;
    try {
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      final image = frame.image;
      final w = image.width, h = image.height;
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(
          recorder, ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()));
      canvas.drawImage(image, Offset.zero, Paint());
      // Tiny, sized relative to image width so it stays consistent at any
      // resolution.
      final fontSize = (w * 0.026).clamp(9.0, 26.0);
      final tp = TextPainter(
        text: TextSpan(
          text: 'AKN',
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.20), // very subtle
            fontSize: fontSize,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.5,
            height: 1.0,
            shadows: [
              Shadow(
                color: Colors.black.withValues(alpha: 0.10),
                blurRadius: 1,
              ),
            ],
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final margin = w * 0.016;
      tp.paint(canvas, Offset(margin, margin));
      final pic = recorder.endRecording();
      final outImg = await pic.toImage(w, h);
      final png = await outImg.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      outImg.dispose();
      if (png == null) return bytes;
      // dart:ui can only emit lossless PNG, which balloons a few-hundred-KB
      // JPEG photo into several MB. Re-encode to JPEG (native, fast) so the
      // shared file stays the same size class as the original.
      try {
        // q85 is visually indistinguishable from q90 on phone screens for
        // saree photos, ~30-40% smaller — faster to build, upload and send.
        // (WhatsApp recompresses photos again on send anyway.)
        final jpg = await FlutterImageCompress.compressWithList(
          png.buffer.asUint8List(),
          quality: 85,
          format: CompressFormat.jpeg,
        );
        if (jpg.isNotEmpty) return jpg;
      } catch (_) {/* fall through to PNG below */}
      return png.buffer.asUint8List();
    } catch (_) {
      return bytes;
    }
  }

  static Future<List<File>> _resolveFiles({
    required List<Photo> photos,
    required EditService editService,
    required Dio dio,
    double markupPercent = 0,
    double gstPercent = 0,
    Map<String, int>? manualPrices,
  }) async {
    final cacheRoot = await getApplicationSupportDirectory();
    final shareDir = Directory(p.join(cacheRoot.path, 'share'));
    if (!shareDir.existsSync()) shareDir.createSync(recursive: true);
    // Best-effort cleanup of prior shares older than 1 hour.
    final cutoff = DateTime.now().subtract(const Duration(hours: 1));
    for (final f in shareDir.listSync()) {
      try {
        if (f.statSync().modified.isBefore(cutoff)) f.deleteSync();
      } catch (_) {}
    }

    final ts = DateTime.now().millisecondsSinceEpoch;
    final out = List<File?>.filled(photos.length, null, growable: false);
    final doMarkup = markupPercent > 0 || (manualPrices?.isNotEmpty ?? false);

    Future<void> processOne(int i, PriceMarkup? mk) async {
      final ph = photos[i];
      Uint8List bytes;
      final edited = await editService.read(ph.id);
      if (edited != null && edited.isNotEmpty) {
        bytes = edited;
      } else {
        try {
          final res = await dio.get<List<int>>(
            DriveUrls.thumbnail(ph.id, width: 1280),
            options: Options(responseType: ResponseType.bytes),
          );
          bytes = Uint8List.fromList(res.data ?? const []);
        } catch (_) {
          return;
        }
      }
      if (bytes.isEmpty) return;
      // Price overlay: a manual per-photo price wins; otherwise apply the
      // uniform margin % to the price detected on the photo.
      final manual = manualPrices?[ph.id];
      if (mk != null && manual != null) {
        bytes = await mk.apply(
          imageBytes: bytes,
          knownPrice: ph.price ?? manual,
          percent: 0,
          overridePrice: manual,
          tmpKey: '${ts}_$i',
        );
      } else if (mk != null && markupPercent > 0 && ph.price != null) {
        bytes = await mk.apply(
          imageBytes: bytes,
          knownPrice: ph.price!,
          percent: markupPercent,
          gstPercent: gstPercent,
          tmpKey: '${ts}_$i',
        );
      }
      // Quietly stamp the shop's "AKN" mark on every shared design (subtle,
      // top-left corner) so shared photos stay attributable.
      bytes = await _stampWatermark(bytes);
      final stem = (ph.designNumber ?? ph.filename)
          .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
      final f = File(p.join(shareDir.path, '${ts}_${i}_$stem.jpg'));
      await f.writeAsBytes(bytes, flush: true);
      out[i] = f;
    }

    final queue = List<int>.generate(photos.length, (i) => i);
    Future<void> worker() async {
      // Markup needs its own ML Kit recognizer per worker. Plain downloads
      // don't, so the no-markup path stays as fast as before.
      final mk = doMarkup ? PriceMarkup() : null;
      try {
        while (queue.isNotEmpty) {
          final i = queue.removeAt(0);
          await processOne(i, mk);
        }
      } finally {
        mk?.close();
      }
    }

    // OCR is heavy, so the markup path runs fewer workers; the plain path can
    // saturate the network pipe.
    final concurrency = doMarkup ? 4 : 16;
    final n = concurrency > photos.length ? photos.length : concurrency;
    await Future.wait(List.generate(n < 1 ? 1 : n, (_) => worker()));

    return out.whereType<File>().toList();
  }

  /// Send the files to [targetPackage] via Android's SEND / SEND_MULTIPLE
  /// intent. The Kotlin side of [_channel] uses FileProvider.getUriForFile to
  /// construct proper Uri parcelable extras so WhatsApp can read the files
  /// and pre-fills the share screen with them.
  static Future<void> _launchWhatsAppIntent({
    required List<File> files,
    required String? message,
    required String targetPackage,
  }) async {
    await _channel.invokeMethod<bool>('shareToPackage', <String, dynamic>{
      'paths': files.map((f) => f.path).toList(),
      'package': targetPackage,
      if (message != null && message.isNotEmpty) 'message': message,
    });
  }
}
