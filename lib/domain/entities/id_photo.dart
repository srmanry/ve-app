import 'dart:math' as math;
import 'dart:typed_data';

import 'image_edit.dart';

/// Photo sizes of the Passport Photo tool.
enum IdPhotoSize {
  passport('Passport / NID', 45, 55, SizeUnit.mm),
  stamp('Stamp', 20, 25, SizeUnit.mm),
  visa('Visa 35×45', 35, 45, SizeUnit.mm),
  us('2×2 inch (US)', 2, 2, SizeUnit.inch),
  online('Online form', 300, 300, SizeUnit.px, maxKb: 100);

  const IdPhotoSize(this.label, this.w, this.h, this.unit, {this.maxKb});
  final String label;
  final double w;
  final double h;
  final SizeUnit unit;
  final int? maxKb;

  int get widthPx => toPixels(w, unit);
  int get heightPx => toPixels(h, unit);
  double get ratio => widthPx / heightPx;

  /// Printed sizes get a print sheet; online-form photos don't.
  bool get printable => unit != SizeUnit.px;

  String get detail {
    String n(double v) => v == v.roundToDouble() ? v.toInt().toString() : '$v';
    final px = '$widthPx×$heightPx px';
    return unit == SizeUnit.px
        ? '$px · max $maxKb KB'
        : '${n(w)}×${n(h)} ${unit.label} · $px';
  }
}

/// Backgrounds offered for ID photos.
enum IdBackground {
  original('Original', null),
  white('White', 0xFFFFFFFF),
  lightBlue('Light blue', 0xFFD9E8F7),
  lightGray('Light gray', 0xFFEAEAEA);

  const IdBackground(this.label, this.color);
  final String label;
  final int? color;
}

/// A 4R (4×6 inch, 300 DPI) print sheet: where each copy goes.
class PrintSheet {
  const PrintSheet(this.width, this.height, this.main, this.extra);

  final int width;
  final int height;

  /// Rects (left, top, width, height) of the main photos.
  final List<(int, int, int, int)> main;

  /// Rects of the extra stamp-size photos, if any.
  final List<(int, int, int, int)> extra;

  int get count => main.length + extra.length;

  static const long = 1800, short = 1200;

  /// Fits as many [w]×[h] photos as possible on a 4R sheet (portrait or
  /// landscape, with or without margins). With [stamps] the space left
  /// below is filled with stamp-size copies.
  static PrintSheet plan(int w, int h, {(int, int)? stamps}) {
    PrintSheet? best;
    for (final (sw, sh) in [(short, long), (long, short)]) {
      for (final (m, g) in [(36, 24), (0, 0)]) {
        final cols = ((sw - 2 * m + g) / (w + g)).floor();
        final rows = ((sh - 2 * m + g) / (h + g)).floor();
        if (cols < 1 || rows < 1) continue;
        // Centre the grid.
        final gridW = cols * w + (cols - 1) * g, gridH = rows * h + (rows - 1) * g;
        final x0 = (sw - gridW) ~/ 2;
        var y0 = (sh - gridH) ~/ 2;
        final extra = <(int, int, int, int)>[];
        if (stamps != null) {
          // Main grid at the top, stamps in the space below it.
          y0 = math.max(m, 24);
          final (tw, th) = stamps;
          final gap = math.max(g, 24);
          final top = y0 + gridH + gap;
          final scols = ((sw - 2 * m + gap) / (tw + gap)).floor();
          final srows = ((sh - m - top + gap) / (th + gap)).floor();
          if (scols > 0 && srows > 0) {
            final sgw = scols * tw + (scols - 1) * gap;
            final sx0 = (sw - sgw) ~/ 2;
            for (var r = 0; r < srows; r++) {
              for (var c = 0; c < scols; c++) {
                extra.add((sx0 + c * (tw + gap), top + r * (th + gap), tw, th));
              }
            }
          }
        }
        final main = [
          for (var r = 0; r < rows; r++)
            for (var c = 0; c < cols; c++) (x0 + c * (w + g), y0 + r * (h + g), w, h),
        ];
        final sheet = PrintSheet(sw, sh, main, extra);
        // Most main copies wins, then most copies overall; margins (easier
        // cutting) win ties since they are tried first.
        if (best == null ||
            sheet.main.length > best.main.length ||
            (sheet.main.length == best.main.length && sheet.count > best.count)) {
          best = sheet;
        }
      }
    }
    return best ?? const PrintSheet(short, long, [], []);
  }
}

/// Head-and-shoulders framing from a person mask ([mask] is [mw]×[mh],
/// 255 = person). Returns a crop of pixel aspect [ratio] for a photo of
/// [photoW]×[photoH], or null when no person is found.
///
/// The person's widest part (shoulders) spans the frame, the top of the
/// head sits a little below the top edge and the head is centred.
CropRect? idPhotoCrop(Uint8List mask, int mw, int mh, int photoW, int photoH, double ratio) {
  var top = -1, minX = mw, maxX = -1;
  for (var y = 0; y < mh; y++) {
    for (var x = 0; x < mw; x++) {
      if (mask[y * mw + x] > 128) {
        if (top < 0) top = y;
        if (x < minX) minX = x;
        if (x > maxX) maxX = x;
      }
    }
  }
  if (top < 0 || maxX <= minX) return null;

  // Head centre: centroid of the top part of the person.
  final personW = (maxX - minX + 1).toDouble();
  final headRows = math.max(4, (personW * 0.5).round());
  double sum = 0;
  var count = 0;
  for (var y = top; y < math.min(mh, top + headRows); y++) {
    for (var x = 0; x < mw; x++) {
      if (mask[y * mw + x] > 128) {
        sum += x;
        count++;
      }
    }
  }
  final headX = count == 0 ? (minX + maxX) / 2 : sum / count;

  // Work in photo pixels.
  final sx = photoW / mw, sy = photoH / mh;
  var cropW = personW * sx * 1.05;
  var cropH = cropW / ratio;
  // Keep the head plus some shoulders in tall frames.
  if (cropH > photoH) {
    cropH = photoH.toDouble();
    cropW = cropH * ratio;
  }
  if (cropW > photoW) {
    cropW = photoW.toDouble();
    cropH = cropW / ratio;
  }
  var left = headX * sx - cropW / 2;
  var topPx = top * sy - cropH * 0.08;
  left = left.clamp(0.0, photoW - cropW);
  topPx = topPx.clamp(0.0, photoH - cropH);
  return CropRect(
    left / photoW,
    topPx / photoH,
    (left + cropW) / photoW,
    (topPx + cropH) / photoH,
  );
}
