import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import '../../domain/entities/image_edit.dart';
import '../video/color_matrix.dart';
import 'spot_healer.dart';

/// Decoded inputs for [ImageRenderer]. [mask] is a person mask (alpha =
/// person) in the source photo's own orientation.
class ImageLayers {
  const ImageLayers({required this.photo, this.logo, this.mask});
  final ui.Image photo;
  final ui.Image? logo;
  final ui.Image? mask;
}

/// Draws an [ImageEdit]. The same code paints the on-screen preview (from a
/// downsized decode) and the saved file (full size), so they always match.
abstract final class ImageRenderer {
  /// Size of the photo after rotation, in source pixels.
  static Size orientedSize(ImageEdit edit, int w, int h) =>
      edit.swapsAxes ? Size(h.toDouble(), w.toDouble()) : Size(w.toDouble(), h.toDouble());

  /// Output pixel size for a [w]×[h] source.
  static (int, int) outputSize(ImageEdit edit, int w, int h) {
    final o = orientedSize(edit, w, h);
    return (
      math.max(1, (o.width * edit.crop.width).round()),
      math.max(1, (o.height * edit.crop.height).round()),
    );
  }

  /// Paints the edited photo filling [out]. With [ignoreCrop] the whole
  /// rotated photo is drawn (used under the crop frame).
  static void paint(
    Canvas canvas,
    Size out,
    ImageLayers layers,
    ImageEdit edit, {
    bool ignoreCrop = false,
  }) {
    final src = layers.photo;
    final o = orientedSize(edit, src.width, src.height);
    final crop = ignoreCrop ? CropRect.full : edit.crop;
    final frame = Offset.zero & out;

    final matrix = ColorMatrix.build(edit.filter, edit.filterStrength, edit.adjustments);
    final look = ColorMatrix.isIdentity(matrix) ? null : ColorFilter.matrix(matrix);
    final basePaint = Paint()..filterQuality = FilterQuality.high;

    // Maps source pixels into the output frame (rotate, flip, crop, scale).
    void transform() {
      canvas.scale(out.width / (o.width * crop.width), out.height / (o.height * crop.height));
      canvas.translate(-crop.left * o.width, -crop.top * o.height);
      canvas.translate(o.width / 2, o.height / 2);
      canvas.rotate(edit.quarterTurns * math.pi / 2);
      canvas.scale(edit.flipX ? -1 : 1, edit.flipY ? -1 : 1);
      canvas.translate(-src.width / 2, -src.height / 2);
    }

    // The photo with its retouch strokes, in source space, then the look
    // (filter + adjustments) over all of it.
    void drawPhoto() {
      if (look != null) canvas.saveLayer(frame, Paint()..colorFilter = look);
      canvas.save();
      transform();
      canvas.drawImage(src, Offset.zero, basePaint);
      _drawRetouch(canvas, src, edit.retouch);
      canvas.restore();
      if (look != null) canvas.restore();
    }

    final srcRect = Rect.fromLTWH(0, 0, src.width.toDouble(), src.height.toDouble());
    final mask = layers.mask;

    canvas.save();
    canvas.clipRect(frame);
    if (edit.cutout && mask != null) {
      switch (edit.background) {
        case CutoutBackground.transparent:
          break;
        case CutoutBackground.white:
          canvas.drawRect(frame, Paint()..color = const Color(0xFFFFFFFF));
        case CutoutBackground.color:
          canvas.drawRect(frame, Paint()..color = Color(edit.backgroundColor));
        case CutoutBackground.blur:
          final sigma = math.min(out.width, out.height) * 0.025;
          canvas.saveLayer(
            frame,
            Paint()..imageFilter = ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma, tileMode: TileMode.clamp),
          );
          drawPhoto();
          canvas.restore();
      }
      // Person only: photo, then keep it where the mask is opaque.
      canvas.saveLayer(frame, Paint());
      drawPhoto();
      canvas.save();
      transform();
      canvas.drawImageRect(
        mask,
        Rect.fromLTWH(0, 0, mask.width.toDouble(), mask.height.toDouble()),
        srcRect,
        Paint()
          ..blendMode = BlendMode.dstIn
          ..filterQuality = FilterQuality.medium,
      );
      canvas.restore();
      canvas.restore();
    } else {
      drawPhoto();
    }

    if (!ignoreCrop && edit.vignette > 0) {
      final center = frame.center;
      final radius = math.sqrt(out.width * out.width + out.height * out.height) / 2;
      canvas.drawRect(
        frame,
        Paint()
          // srcATop: only darkens existing pixels, never transparent areas.
          ..blendMode = BlendMode.srcATop
          ..shader = ui.Gradient.radial(
            center,
            radius,
            [const Color(0x00000000), Color.fromRGBO(0, 0, 0, 0.8 * edit.vignette.clamp(0, 1))],
            [0.4, 1],
          ),
      );
    }

    final logo = layers.logo;
    final placement = edit.logo;
    if (logo != null && placement != null && !ignoreCrop) {
      final rect = logoRect(placement, out, logo.width / logo.height);
      canvas.drawImageRect(
        logo,
        Rect.fromLTWH(0, 0, logo.width.toDouble(), logo.height.toDouble()),
        rect,
        Paint()
          ..filterQuality = FilterQuality.high
          ..color = Color.fromRGBO(0, 0, 0, placement.opacity.clamp(0, 1)),
      );
    }
    if (!ignoreCrop) {
      for (final t in edit.texts) {
        _drawText(canvas, t, out);
      }
    }
    canvas.restore();
  }

  // ----------------------------------------------------------------- retouch

  /// Brush strokes, drawn in source space. Consecutive strokes of the same
  /// tool and strength share one layer (fast preview with many strokes).
  static void _drawRetouch(Canvas canvas, ui.Image src, List<RetouchStroke> strokes) {
    final list = strokes.where((s) => s.tool != RetouchTool.heal).toList();
    if (list.isEmpty) return;
    final long = math.max(src.width, src.height).toDouble();
    final bounds = Rect.fromLTWH(0, 0, src.width.toDouble(), src.height.toDouble());
    var i = 0;
    while (i < list.length) {
      var j = i + 1;
      while (j < list.length && list[j].tool == list[i].tool && list[j].strength == list[i].strength) {
        j++;
      }
      final group = list.sublist(i, j);
      canvas.saveLayer(bounds, Paint());
      canvas.drawImage(src, Offset.zero, _effectPaint(group.first.tool, long));
      canvas.saveLayer(bounds, Paint()..blendMode = BlendMode.dstIn);
      for (final s in group) {
        _drawStrokeMask(canvas, s, src.width, src.height, long);
      }
      canvas.restore();
      canvas.restore();
      i = j;
    }
  }

  static Paint _effectPaint(RetouchTool tool, double long) {
    final p = Paint()..filterQuality = FilterQuality.high;
    switch (tool) {
      case RetouchTool.heal:
        break;
      case RetouchTool.smooth:
        final sigma = long * 0.004;
        p.imageFilter = ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma, tileMode: TileMode.clamp);
      case RetouchTool.blur:
        final sigma = long * 0.02;
        p.imageFilter = ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma, tileMode: TileMode.clamp);
      case RetouchTool.brighten:
        p.colorFilter = const ColorFilter.matrix([
          1.35, 0, 0, 0, 12, //
          0, 1.35, 0, 0, 12, //
          0, 0, 1.35, 0, 12, //
          0, 0, 0, 1, 0, //
        ]);
      case RetouchTool.darken:
        p.colorFilter = const ColorFilter.matrix([
          0.68, 0, 0, 0, 0, //
          0, 0.68, 0, 0, 0, //
          0, 0, 0.68, 0, 0, //
          0, 0, 0, 1, 0, //
        ]);
      case RetouchTool.whiten:
        // Mostly desaturate (yellow out of teeth / red out of eyes) and lift.
        const k = 0.75, lr = 0.2126 * k, lg = 0.7152 * k, lb = 0.0722 * k, keep = 1 - k;
        p.colorFilter = const ColorFilter.matrix([
          (lr + keep) * 1.12, lg * 1.12, lb * 1.12, 0, 18, //
          lr * 1.12, (lg + keep) * 1.12, lb * 1.12, 0, 18, //
          lr * 1.12, lg * 1.12, (lb + keep) * 1.12, 0, 18, //
          0, 0, 0, 1, 0, //
        ]);
    }
    return p;
  }

  static void _drawStrokeMask(Canvas canvas, RetouchStroke s, int w, int h, double long) {
    final r = s.radius * long;
    final paint = Paint()
      ..color = Color.fromRGBO(255, 255, 255, s.strength.clamp(0, 1))
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, r * 0.35)
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final pts = [for (final (x, y) in s.points) Offset(x * w, y * h)];
    if (pts.length == 1) {
      canvas.drawCircle(pts.first, r, paint);
      return;
    }
    final path = Path()..moveTo(pts.first.dx, pts.first.dy);
    for (final pt in pts.skip(1)) {
      path.lineTo(pt.dx, pt.dy);
    }
    canvas.drawPath(
      path,
      paint
        ..style = PaintingStyle.stroke
        ..strokeWidth = r * 2,
    );
  }

  // -------------------------------------------------------------------- text

  static TextPainter _textPainter(PhotoText t, Size out) {
    final fontSize = t.size * math.min(out.width, out.height);
    return TextPainter(
      text: TextSpan(
        text: t.text,
        style: TextStyle(
          fontFamily: t.font,
          fontSize: fontSize,
          height: 1.15,
          color: Color(t.color),
          fontWeight: t.bold ? FontWeight.w700 : FontWeight.w400,
          shadows: t.shadow && !t.background
              ? [
                  Shadow(
                    color: const Color(0x99000000),
                    blurRadius: fontSize * 0.15,
                    offset: Offset(0, fontSize * 0.05),
                  ),
                ]
              : null,
        ),
      ),
      textAlign: TextAlign.center,
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: out.width * 0.92);
  }

  /// Box a text label covers on an [out]-sized photo (including its padding).
  static Rect textRect(PhotoText t, Size out) {
    final tp = _textPainter(t, out);
    final pad = t.background ? tp.preferredLineHeight * 0.3 : 0.0;
    final r = Rect.fromCenter(
      center: Offset(t.x * out.width, t.y * out.height),
      width: tp.width + pad * 2,
      height: tp.height + pad * 2,
    );
    tp.dispose();
    return r;
  }

  static void _drawText(Canvas canvas, PhotoText t, Size out) {
    if (t.text.trim().isEmpty) return;
    final tp = _textPainter(t, out);
    final center = Offset(t.x * out.width, t.y * out.height);
    if (t.background) {
      final pad = tp.preferredLineHeight * 0.3;
      final box = Rect.fromCenter(center: center, width: tp.width + pad * 2, height: tp.height + pad * 2);
      final light = Color(t.color).computeLuminance() > 0.5;
      canvas.drawRRect(
        RRect.fromRectAndRadius(box, Radius.circular(pad)),
        Paint()..color = light ? const Color(0x99000000) : const Color(0xE6FFFFFF),
      );
    }
    tp.paint(canvas, center - Offset(tp.width / 2, tp.height / 2));
    tp.dispose();
  }

  /// Where a logo of [aspect] (w/h) sits on an [out]-sized photo.
  static Rect logoRect(ImageLogo logo, Size out, double aspect) {
    final w = math.min(out.width, out.height) * logo.size;
    final h = w / aspect;
    return Rect.fromCenter(center: Offset(logo.x * out.width, logo.y * out.height), width: w, height: h);
  }

  /// Heals the spots of [edit] on [photo] (see `healSpots`). Returns
  /// [photo] itself when there is nothing to heal.
  static Future<ui.Image> applyHeals(ui.Image photo, ImageEdit edit) async {
    final spots = healSpotsFor(edit, photo.width, photo.height);
    if (spots.isEmpty) return photo;
    final data = await photo.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
    if (data == null) return photo;
    final healed = await compute(
      healSpots,
      HealJob(data.buffer.asUint8List(), photo.width, photo.height, spots),
    );
    return decodeRgba(healed, photo.width, photo.height);
  }

  /// Heal spots of [edit] in pixels of a [w]×[h] photo.
  static List<(double, double, double)> healSpotsFor(ImageEdit edit, int w, int h) {
    final long = math.max(w, h).toDouble();
    return [
      for (final s in edit.heals)
        for (final (x, y) in s.points) (x * w, y * h, s.radius * long),
    ];
  }

  /// Renders at full size and returns PNG bytes.
  static Future<Uint8List> renderPng(ImageLayers layers, ImageEdit edit) async {
    final (w, h) = outputSize(edit, layers.photo.width, layers.photo.height);
    final recorder = ui.PictureRecorder();
    paint(Canvas(recorder), Size(w.toDouble(), h.toDouble()), layers, edit);
    final picture = recorder.endRecording();
    final image = await picture.toImage(w, h);
    picture.dispose();
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) throw StateError('PNG encoding failed');
      return data.buffer.asUint8List();
    } finally {
      image.dispose();
    }
  }

  /// Turns an 8-bit person mask into an image whose alpha is the mask.
  static Future<ui.Image> maskImage(Uint8List gray, int w, int h) {
    final rgba = Uint8List(w * h * 4);
    for (var i = 0, j = 0; i < w * h; i++, j += 4) {
      rgba[j] = 255;
      rgba[j + 1] = 255;
      rgba[j + 2] = 255;
      rgba[j + 3] = gray[i];
    }
    return decodeRgba(rgba, w, h);
  }

  static Future<ui.Image> decodeRgba(Uint8List rgba, int w, int h) async {
    final buffer = await ui.ImmutableBuffer.fromUint8List(rgba);
    final descriptor = ui.ImageDescriptor.raw(
      buffer,
      width: w,
      height: h,
      pixelFormat: ui.PixelFormat.rgba8888,
    );
    final codec = await descriptor.instantiateCodec();
    final frame = await codec.getNextFrame();
    codec.dispose();
    descriptor.dispose();
    buffer.dispose();
    return frame.image;
  }

  /// Decodes a file, optionally downsized so its long side ≤ [maxSide].
  static Future<ui.Image> decodeFile(Uint8List bytes, {int? maxSide}) async {
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    final codec = await ui.instantiateImageCodecWithSize(
      buffer,
      getTargetSize: (w, h) {
        if (maxSide == null || math.max(w, h) <= maxSide) return ui.TargetImageSize(width: w, height: h);
        final f = maxSide / math.max(w, h);
        return ui.TargetImageSize(width: math.max(1, (w * f).round()), height: math.max(1, (h * f).round()));
      },
    );
    final frame = await codec.getNextFrame();
    codec.dispose();
    return frame.image;
  }
}
