import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Overlays a marked-up price onto a photo and NORMALISES it to one uniform
/// format: "Rs <newPrice>/-".
///
/// However the shop printed it — "Rs 200/-", "Rs 200 -", "200/- Rs" — we:
///   1. Find the price number on a line carrying a price cue (rs/₹//-).
///   2. Group it with any adjacent "Rs"/"₹" and "/-"/"-" elements (never a
///      fabric-name word).
///   3. Erase that whole group with the sampled tag colour.
///   4. Redraw "Rs <newPrice>/-" in its place, sized to the number's height and
///      bounded so it never reaches a neighbouring word.
///
/// Result: every photo shows the marked-up price in the identical "Rs X/-"
/// style, with the original value fully erased (no ghost digits).
class PriceMarkup {
  final TextRecognizer _recognizer =
      TextRecognizer(script: TextRecognitionScript.latin);

  void close() => _recognizer.close();

  Future<Uint8List> apply({
    required Uint8List imageBytes,
    required int knownPrice,
    required double percent,
    required String tmpKey,
    int? overridePrice,
    double gstPercent = 0,
  }) async {
    if ((overridePrice == null && percent <= 0) || imageBytes.isEmpty) {
      return imageBytes;
    }
    File? tmp;
    try {
      tmp = await _writeTemp(tmpKey, imageBytes);
      final recognized =
          await _recognizer.processImage(InputImage.fromFilePath(tmp.path));

      final matches = _findPrintedPrices(recognized);
      if (matches.isEmpty) return imageBytes;

      final codec = await ui.instantiateImageCodec(imageBytes);
      final frame = await codec.getNextFrame();
      final image = frame.image;
      final w = image.width;
      final h = image.height;
      final rgbaData =
          await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (rgbaData == null) {
        image.dispose();
        return imageBytes;
      }
      final rgba = rgbaData.buffer.asUint8List();

      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(
          recorder, ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()));
      canvas.drawImage(image, Offset.zero, Paint());

      for (final m in matches) {
        final numBox = _clamp(m.numberBox, w, h);
        final group = _clamp(m.groupBox, w, h);
        if (numBox.height < 2 || group.width < 1) continue;

        // Either a manually-entered exact price, or the percentage markup of
        // the price detected on the photo.
        final int newNum;
        if (overridePrice != null) {
          newNum = overridePrice;
        } else {
          // Margin, then optional GST on top of the marked-up price.
          final raw = m.value * (1 + percent / 100) * (1 + gstPercent / 100);
          newNum = (raw / 5).round() * 5;
        }
        // Always render the uniform "Rs <num>/-" format.
        final text = 'Rs $newNum/-';

        // Sample tag colour around the whole group, ink from the digits.
        final bg = _dominantRing(rgba, w, h, group);
        final ink = _inkColor(rgba, w, h, numBox, bg);
        final bgColor = Color.fromARGB(255, bg.$1, bg.$2, bg.$3);
        final inkColor = Color.fromARGB(255, ink.$1, ink.$2, ink.$3);

        // Erase the entire group (padded) so Rs + old number + old suffix are
        // all wiped — no ghost digit, no stray dot/slash. Extra left pad in
        // case a separately-detected "Rs" sat just outside the group box.
        final padX = numBox.height * 0.45;
        final padY = numBox.height * 0.24;
        final eraseRight =
            math.min(group.right + padX, m.rightBarrier).toDouble();
        final cover = ui.Rect.fromLTRB(
          (group.left - padX).clamp(0.0, w.toDouble()).toDouble(),
          (group.top - padY).clamp(0.0, h.toDouble()).toDouble(),
          eraseRight.clamp(0.0, w.toDouble()).toDouble(),
          (group.bottom + padY).clamp(0.0, h.toDouble()).toDouble(),
        );
        canvas.drawRect(
          cover,
          Paint()
            ..color = bgColor
            ..isAntiAlias = false,
        );

        // Redraw "Rs <num>/-" sized to the number height, left-anchored at the
        // group's left edge, capped so it never reaches the next word.
        const refSize = 100.0;
        final tp = _build(text, refSize, inkColor);
        final natW = tp.width <= 0 ? 1.0 : tp.width;
        final natH = tp.height <= 0 ? 1.0 : tp.height;
        double scale = numBox.height / natH;
        final availW = (m.rightBarrier - group.left).clamp(1.0, w.toDouble());
        if (natW * scale > availW) scale = availW / natW;
        final dy = numBox.center.dy - (natH * scale) / 2;
        canvas.save();
        canvas.translate(group.left, dy);
        canvas.scale(scale, scale);
        tp.paint(canvas, Offset.zero);
        canvas.restore();
      }

      final pic = recorder.endRecording();
      final outImg = await pic.toImage(w, h);
      final png = await outImg.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      outImg.dispose();
      if (png == null) return imageBytes;
      return png.buffer.asUint8List();
    } catch (_) {
      return imageBytes;
    } finally {
      if (tmp != null) {
        try {
          await tmp.delete();
        } catch (_) {}
      }
    }
  }

  /// Finds price numbers + their full price group (Rs + number + suffix) and a
  /// right barrier (the next word's left edge) so the uniform redraw never
  /// covers a fabric name.
  ///
  /// Absorption scans ALL elements in the image (not just the same OCR line),
  /// because ML Kit sometimes splits "Rs" and the number into separate
  /// lines/blocks — which previously left a ghost "Rs" beside the redraw.
  List<({ui.Rect numberBox, ui.Rect groupBox, double rightBarrier, int value})>
      _findPrintedPrices(RecognizedText recognized) {
    final out = <({
      ui.Rect numberBox,
      ui.Rect groupBox,
      double rightBarrier,
      int value
    })>[];
    final cueLine = RegExp(r'(rs|₹|/-)', caseSensitive: false);
    final digitRun = RegExp(r'\d{3,6}');
    // A "word" = 3+ consecutive letters (fabric name etc.). Everything shorter
    // ("Rs", "F", "/-", "·") is treated as absorbable price decoration.
    final isWord = RegExp(r'[A-Za-z]{3,}');

    double gapBetween(ui.Rect a, ui.Rect b) {
      if (b.left >= a.right) return b.left - a.right;
      if (a.left >= b.right) return a.left - b.right;
      return 0; // overlap
    }

    // Flatten every element in the image with its text + box, once.
    final all = <({String text, ui.Rect box})>[];
    for (final block in recognized.blocks) {
      for (final line in block.lines) {
        for (final el in line.elements) {
          all.add((text: el.text.trim(), box: el.boundingBox));
        }
      }
    }
    bool absorbable(String s) => s.isNotEmpty && !isWord.hasMatch(s);

    for (final block in recognized.blocks) {
      for (final line in block.lines) {
        if (!cueLine.hasMatch(line.text)) continue;
        for (final el in line.elements) {
          final t = el.text;
          final mm = digitRun.allMatches(t).toList();
          if (mm.isEmpty) continue;
          mm.sort((a, b) => b.group(0)!.length.compareTo(a.group(0)!.length));
          final value = int.tryParse(mm.first.group(0)!);
          if (value == null || value < 80 || value > 100000) continue;

          final numBox = el.boundingBox;
          final hgt = numBox.height;
          var group = numBox;

          // Grow over adjacent absorbable elements IMAGE-WIDE, repeatedly, so a
          // separately-detected "Rs" / stray "F" / "/-" all get pulled in even
          // if ML Kit put them on a different line.
          bool grew = true;
          int guard = 0;
          while (grew && guard++ < 12) {
            grew = false;
            for (final e in all) {
              final eb = e.box;
              if (group.contains(eb.center)) continue;
              // Same row as the number (vertical overlap).
              final vOverlap = (math.min(eb.bottom, group.bottom) -
                      math.max(eb.top, group.top)) >
                  hgt * 0.3;
              if (!vOverlap) continue;
              if (gapBetween(group, eb) < hgt * 1.6 && absorbable(e.text)) {
                final ng = group.expandToInclude(eb);
                if (ng != group) {
                  group = ng;
                  grew = true;
                }
              }
            }
          }

          // Right barrier: nearest real word to the right of the group.
          double rightBarrier = double.infinity;
          for (final e in all) {
            if (e.box.left < group.right) continue;
            final vOverlap = (math.min(e.box.bottom, group.bottom) -
                    math.max(e.box.top, group.top)) >
                hgt * 0.3;
            if (!vOverlap) continue;
            if (isWord.hasMatch(e.text)) {
              final b = e.box.left - hgt * 0.15;
              if (b < rightBarrier) rightBarrier = b;
            }
          }

          out.add((
            numberBox: numBox,
            groupBox: group,
            rightBarrier: rightBarrier,
            value: value,
          ));
        }
      }
    }
    return out;
  }

  Future<File> _writeTemp(String key, Uint8List bytes) async {
    final dir = await getTemporaryDirectory();
    final safe = key.replaceAll(RegExp(r'[^A-Za-z0-9_]'), '_');
    final f = File(p.join(dir.path, 'mk_$safe.jpg'));
    await f.writeAsBytes(bytes, flush: true);
    return f;
  }

  ui.Rect _clamp(ui.Rect r, int w, int h) {
    return ui.Rect.fromLTRB(
      r.left.clamp(0.0, w.toDouble()).toDouble(),
      r.top.clamp(0.0, h.toDouble()).toDouble(),
      r.right.clamp(0.0, w.toDouble()).toDouble(),
      r.bottom.clamp(0.0, h.toDouble()).toDouble(),
    );
  }

  /// Dominant (mode) colour of a ring just outside [box].
  (int, int, int) _dominantRing(Uint8List rgba, int w, int h, ui.Rect box) {
    final band = math.max(3, (box.height * 0.5).round());
    final counts = <int, int>{};
    final sumR = <int, int>{}, sumG = <int, int>{}, sumB = <int, int>{};

    void add(int x, int y) {
      if (x < 0 || y < 0 || x >= w || y >= h) return;
      final i = (y * w + x) * 4;
      final r = rgba[i], g = rgba[i + 1], b = rgba[i + 2];
      final key = ((r >> 5) << 6) | ((g >> 5) << 3) | (b >> 5);
      counts[key] = (counts[key] ?? 0) + 1;
      sumR[key] = (sumR[key] ?? 0) + r;
      sumG[key] = (sumG[key] ?? 0) + g;
      sumB[key] = (sumB[key] ?? 0) + b;
    }

    final l = box.left.round(), r = box.right.round();
    final t = box.top.round(), b = box.bottom.round();
    for (int y = t; y <= b; y++) {
      for (int d = 1; d <= band; d++) {
        add(l - d, y);
        add(r + d, y);
      }
    }
    for (int x = l - band; x <= r + band; x++) {
      for (int d = 1; d <= (band ~/ 2) + 1; d++) {
        add(x, t - d);
        add(x, b + d);
      }
    }
    if (counts.isEmpty) return (255, 255, 255);
    int bestKey = counts.keys.first, bestN = -1;
    counts.forEach((k, n) {
      if (n > bestN) {
        bestN = n;
        bestKey = k;
      }
    });
    return (
      (sumR[bestKey]! / bestN).round(),
      (sumG[bestKey]! / bestN).round(),
      (sumB[bestKey]! / bestN).round(),
    );
  }

  /// Ink colour = average of in-box pixels that differ most from the bg.
  (int, int, int) _inkColor(
      Uint8List rgba, int w, int h, ui.Rect box, (int, int, int) bg) {
    final bgLum = bg.$1 * 0.299 + bg.$2 * 0.587 + bg.$3 * 0.114;
    int n = 0, sr = 0, sg = 0, sb = 0;
    final l = box.left.round(), t = box.top.round();
    final r = box.right.round(), b = box.bottom.round();
    for (int y = t; y < b; y++) {
      for (int x = l; x < r; x++) {
        if (x < 0 || y < 0 || x >= w || y >= h) continue;
        final i = (y * w + x) * 4;
        final lum = rgba[i] * 0.299 + rgba[i + 1] * 0.587 + rgba[i + 2] * 0.114;
        if ((lum - bgLum).abs() > 60) {
          sr += rgba[i];
          sg += rgba[i + 1];
          sb += rgba[i + 2];
          n++;
        }
      }
    }
    if (n < 6) return bgLum > 128 ? (20, 20, 20) : (245, 245, 245);
    return ((sr / n).round(), (sg / n).round(), (sb / n).round());
  }

  TextPainter _build(String text, double fontSize, Color color) => TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(
            color: color,
            fontSize: fontSize,
            fontWeight: FontWeight.w700,
            height: 1.0,
            letterSpacing: 0,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
}
