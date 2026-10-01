import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import '../../services/image/document_scan.dart';
import '../../services/image/image_renderer.dart';

/// How a scanned page is cleaned up.
enum ScanEnhance {
  auto('Auto'),
  original('Original'),
  gray('Gray'),
  bw('B&W');

  const ScanEnhance(this.label);
  final String label;
}

/// One page of a scan: the photo, where the paper is, and its rotation.
class ScanPage {
  ScanPage({required this.path, required this.width, required this.height, Quad? quad})
    : quad = quad ?? defaultQuad;

  /// Absolute path of the imported photo.
  final String path;
  final int width;
  final int height;
  Quad quad;
  int turns = 0;

  /// Small rendered preview (owned by the page).
  ui.Image? thumb;
}

/// Colour matrix for [mode] given the page's ink/paper levels.
List<double> enhanceMatrix(ScanEnhance mode, double lo, double hi) {
  const lr = 0.299, lg = 0.587, lb = 0.114;
  switch (mode) {
    case ScanEnhance.original:
      return const [1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0];
    case ScanEnhance.auto:
      // Paper to white, ink kept, colours a little livelier.
      final k = 255 / math.max(1, hi - lo);
      const s = 1.15, t = (1 - s) / 3;
      List<double> row(int c) => [
        for (var i = 0; i < 3; i++) (i == c ? s + t : t) * k,
        0,
        -lo * k,
      ];
      return [...row(0), ...row(1), ...row(2), 0, 0, 0, 1, 0];
    case ScanEnhance.gray:
      final k = 255 / math.max(1, hi - lo);
      final row = [lr * k, lg * k, lb * k, 0.0, -lo * k];
      return [...row, ...row, ...row, 0, 0, 0, 1, 0];
    case ScanEnhance.bw:
      // Steep curve: text black, paper and shadows white.
      final h2 = hi * 0.97, l2 = h2 - (hi - lo) * 0.45;
      final k = 255 / math.max(1, h2 - l2);
      final row = [lr * k, lg * k, lb * k, 0.0, -l2 * k];
      return [...row, ...row, ...row, 0, 0, 0, 1, 0];
  }
}

/// Isolate entry: straighten the page and measure its levels.
(Uint8List, double, double) _warpAndLevels(WarpJob job) {
  final out = warpPage(job);
  final (lo, hi) = pageLevels(out);
  return (out, lo, hi);
}

/// Isolate entry: corner detection on a small copy.
Quad? _detect(DetectJob job) => detectDocument(job);

abstract final class ScanRenderer {
  /// Finds the page corners (or null) using a ≤ 320 px copy of the photo.
  static Future<Quad?> detect(String path) async {
    final img = await ImageRenderer.decodeFile(await File(path).readAsBytes(), maxSide: 320);
    try {
      final data = await img.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
      if (data == null) return null;
      return await compute(_detect, DetectJob(data.buffer.asUint8List(), img.width, img.height));
    } finally {
      img.dispose();
    }
  }

  /// The finished page: straightened, rotated and enhanced, with its long
  /// side at most [maxSide].
  static Future<ui.Image> render(ScanPage page, ScanEnhance mode, {required int maxSide}) async {
    // Decode a bit larger than the output so the warp keeps detail.
    final photo = await ImageRenderer.decodeFile(
      await File(page.path).readAsBytes(),
      maxSide: math.min(4096, (maxSide * 1.6).round()),
    );
    final ui.Image flat;
    final double lo, hi;
    try {
      final data = await photo.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
      final (ow, oh) = pageSize(page.quad, photo.width, photo.height, maxSide: maxSide);
      final (rgba, l, h) = await compute(
        _warpAndLevels,
        WarpJob(data!.buffer.asUint8List(), photo.width, photo.height, page.quad, ow, oh),
      );
      lo = l;
      hi = h;
      flat = await ImageRenderer.decodeRgba(rgba, ow, oh);
    } finally {
      photo.dispose();
    }

    try {
      final swap = page.turns.isOdd;
      final w = swap ? flat.height : flat.width, h = swap ? flat.width : flat.height;
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.translate(w / 2, h / 2);
      canvas.rotate(page.turns * math.pi / 2);
      canvas.translate(-flat.width / 2, -flat.height / 2);
      canvas.drawImage(
        flat,
        Offset.zero,
        Paint()
          ..filterQuality = FilterQuality.high
          ..colorFilter = ColorFilter.matrix(enhanceMatrix(mode, lo, hi)),
      );
      final picture = recorder.endRecording();
      final out = await picture.toImage(w, h);
      picture.dispose();
      return out;
    } finally {
      flat.dispose();
    }
  }
}
