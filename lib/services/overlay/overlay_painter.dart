import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import '../../domain/entities/layer_transform.dart';
import '../../domain/entities/sticker_layer.dart';
import '../../domain/entities/text_layer.dart';

/// Single source of truth for drawing text and sticker layers.
///
/// The preview uses [paintTextContent]/[paintStickerContent] inside a
/// transformed widget, and export uses [rasterize], which applies the same
/// transform on a canvas the size of the output video. All sizes are derived
/// from the canvas size, so a layer looks identical at any resolution.
abstract final class OverlayPainter {
  // --------------------------------------------------------------------- text

  static TextPainter _textPainter(TextLayer layer, Size canvas) {
    final style = layer.style;
    final fontSize = style.fontSize * canvas.height;
    final base = TextStyle(
      fontFamily: style.fontFamily,
      fontSize: fontSize,
      fontWeight: style.bold ? FontWeight.w700 : FontWeight.w400,
      fontStyle: style.italic ? FontStyle.italic : FontStyle.normal,
      color: Color(style.color),
      height: 1.15,
      shadows: style.shadow
          ? [
              Shadow(
                color: const Color(0x99000000),
                blurRadius: fontSize * 0.12,
                offset: Offset(0, fontSize * 0.05),
              ),
            ]
          : null,
    );
    return TextPainter(
      text: TextSpan(text: layer.text.isEmpty ? ' ' : layer.text, style: base),
      textAlign: switch (style.align) {
        TextAlignOption.left => TextAlign.left,
        TextAlignOption.center => TextAlign.center,
        TextAlignOption.right => TextAlign.right,
      },
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: canvas.width * 0.9);
  }

  static EdgeInsets _textPadding(TextLayer layer, Size canvas) {
    final fontSize = layer.style.fontSize * canvas.height;
    return EdgeInsets.symmetric(horizontal: fontSize * 0.3, vertical: fontSize * 0.15);
  }

  /// Unscaled size of the text box (text + background padding).
  static Size measureText(TextLayer layer, Size canvas) {
    final painter = _textPainter(layer, canvas);
    final pad = _textPadding(layer, canvas);
    final size = Size(painter.width + pad.horizontal, painter.height + pad.vertical);
    painter.dispose();
    return size;
  }

  /// Paints the text box with its top-left corner at the origin.
  static void paintTextContent(Canvas canvas, TextLayer layer, Size canvasSize) {
    final style = layer.style;
    final painter = _textPainter(layer, canvasSize);
    final pad = _textPadding(layer, canvasSize);
    final box = Size(painter.width + pad.horizontal, painter.height + pad.vertical);
    final fontSize = style.fontSize * canvasSize.height;

    final opacity = style.opacity.clamp(0.0, 1.0);
    if (opacity < 1) {
      canvas.saveLayer(Offset.zero & box, Paint()..color = Color.fromRGBO(0, 0, 0, opacity));
    }

    if (style.backgroundColor != null) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(Offset.zero & box, Radius.circular(fontSize * 0.25)),
        Paint()..color = Color(style.backgroundColor!),
      );
    }

    final origin = Offset(pad.left, pad.top);
    if (style.strokeWidth > 0) {
      // Outline pass (carries the shadow) underneath a shadow-less fill pass.
      final baseStyle = (painter.text! as TextSpan).style!;
      TextPainter variant(TextStyle s) => TextPainter(
        text: TextSpan(text: layer.text.isEmpty ? ' ' : layer.text, style: s),
        textAlign: painter.textAlign,
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: canvasSize.width * 0.9);
      final outline = variant(
        TextStyle(
          fontFamily: baseStyle.fontFamily,
          fontSize: baseStyle.fontSize,
          fontWeight: baseStyle.fontWeight,
          fontStyle: baseStyle.fontStyle,
          height: baseStyle.height,
          shadows: baseStyle.shadows,
          foreground: Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = style.strokeWidth * fontSize
            ..strokeJoin = StrokeJoin.round
            ..color = Color(style.strokeColor),
        ),
      );
      final fill = variant(baseStyle.copyWith(shadows: const []));
      outline.paint(canvas, origin);
      fill.paint(canvas, origin);
      outline.dispose();
      fill.dispose();
    } else {
      painter.paint(canvas, origin);
    }

    if (opacity < 1) canvas.restore();
    painter.dispose();
  }

  // ------------------------------------------------------------------ sticker

  /// Stickers are square; scale 1 = 20% of the canvas' shorter side.
  static Size stickerBaseSize(Size canvas) {
    final s = math.min(canvas.width, canvas.height) * 0.2;
    return Size(s, s);
  }

  /// Draws a logo fitted (aspect kept) inside the square sticker box — the
  /// same box the preview uses with `BoxFit.contain`.
  static void paintLogo(Canvas canvas, ui.Image image, Size box, double opacity) {
    paintImage(
      canvas: canvas,
      rect: Offset.zero & box,
      image: image,
      fit: BoxFit.contain,
      opacity: opacity.clamp(0.0, 1.0),
      filterQuality: FilterQuality.high,
    );
  }

  static Future<ui.Image> _loadImage(String path) async {
    final codec = await ui.instantiateImageCodec(await File(path).readAsBytes());
    final frame = await codec.getNextFrame();
    codec.dispose();
    return frame.image;
  }

  static void paintStickerContent(Canvas canvas, StickerLayer layer, Size canvasSize) {
    final size = stickerBaseSize(canvasSize);
    final opacity = layer.opacity.clamp(0.0, 1.0);
    if (opacity < 1) {
      canvas.saveLayer(Offset.zero & size, Paint()..color = Color.fromRGBO(0, 0, 0, opacity));
    }
    paintSticker(canvas, layer.sticker, size);
    if (opacity < 1) canvas.restore();
  }

  /// Draws [sticker] filling a box of [size] at the origin. Also used by the
  /// sticker picker grid.
  static void paintSticker(Canvas canvas, StickerSpec sticker, Size size) {
    // Logos are image files: drawn by [paintLogo] / an Image widget.
    if (sticker.isImage) return;
    if (sticker.kind == StickerKind.emoji) {
      final tp = TextPainter(
        text: TextSpan(
          text: sticker.value as String,
          style: TextStyle(fontSize: size.height * 0.8, height: 1.0),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset((size.width - tp.width) / 2, (size.height - tp.height) / 2));
      tp.dispose();
      return;
    }
    _paintShape(canvas, sticker.value as StickerShape, Color(sticker.color), size);
  }

  static void _paintShape(Canvas canvas, StickerShape shape, Color color, Size size) {
    final w = size.width, h = size.height;
    final fill = Paint()
      ..color = color
      ..isAntiAlias = true;
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = w * 0.09
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final c = Offset(w / 2, h / 2);
    final r = w * 0.42;

    switch (shape) {
      case StickerShape.circle:
        canvas.drawCircle(c, r, fill);
      case StickerShape.ring:
        canvas.drawCircle(c, r - stroke.strokeWidth / 2, stroke);
      case StickerShape.square:
        canvas.drawRect(Rect.fromCircle(center: c, radius: r * 0.9), fill);
      case StickerShape.roundedSquare:
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromCircle(center: c, radius: r * 0.9),
            Radius.circular(w * 0.15),
          ),
          fill,
        );
      case StickerShape.triangle:
        canvas.drawPath(
          Path()
            ..moveTo(w / 2, h * 0.1)
            ..lineTo(w * 0.92, h * 0.86)
            ..lineTo(w * 0.08, h * 0.86)
            ..close(),
          fill,
        );
      case StickerShape.star:
        canvas.drawPath(_starPath(c, r, r * 0.45, 5), fill);
      case StickerShape.sparkle:
        canvas.drawPath(_starPath(c, r, r * 0.18, 4), fill);
      case StickerShape.heart:
        final path = Path()
          ..moveTo(w / 2, h * 0.88)
          ..cubicTo(w * -0.05, h * 0.55, w * 0.15, h * 0.02, w / 2, h * 0.3)
          ..cubicTo(w * 0.85, h * 0.02, w * 1.05, h * 0.55, w / 2, h * 0.88)
          ..close();
        canvas.drawPath(path, fill);
      case StickerShape.arrowRight:
      case StickerShape.arrowLeft:
      case StickerShape.arrowUp:
      case StickerShape.arrowDown:
        final angle = switch (shape) {
          StickerShape.arrowRight => 0.0,
          StickerShape.arrowDown => math.pi / 2,
          StickerShape.arrowLeft => math.pi,
          _ => -math.pi / 2,
        };
        canvas.save();
        canvas.translate(c.dx, c.dy);
        canvas.rotate(angle);
        canvas.translate(-c.dx, -c.dy);
        canvas.drawPath(
          Path()
            ..moveTo(w * 0.08, h * 0.4)
            ..lineTo(w * 0.55, h * 0.4)
            ..lineTo(w * 0.55, h * 0.2)
            ..lineTo(w * 0.94, h * 0.5)
            ..lineTo(w * 0.55, h * 0.8)
            ..lineTo(w * 0.55, h * 0.6)
            ..lineTo(w * 0.08, h * 0.6)
            ..close(),
          fill,
        );
        canvas.restore();
      case StickerShape.speechBubble:
        canvas.drawRRect(
          RRect.fromLTRBR(w * 0.06, h * 0.12, w * 0.94, h * 0.7, Radius.circular(w * 0.16)),
          fill,
        );
        canvas.drawPath(
          Path()
            ..moveTo(w * 0.28, h * 0.66)
            ..lineTo(w * 0.22, h * 0.9)
            ..lineTo(w * 0.48, h * 0.68)
            ..close(),
          fill,
        );
      case StickerShape.check:
        canvas.drawPath(
          Path()
            ..moveTo(w * 0.15, h * 0.52)
            ..lineTo(w * 0.4, h * 0.76)
            ..lineTo(w * 0.86, h * 0.24),
          stroke..strokeWidth = w * 0.13,
        );
      case StickerShape.cross:
        final p = stroke..strokeWidth = w * 0.13;
        canvas.drawLine(Offset(w * 0.2, h * 0.2), Offset(w * 0.8, h * 0.8), p);
        canvas.drawLine(Offset(w * 0.8, h * 0.2), Offset(w * 0.2, h * 0.8), p);
      case StickerShape.banner:
        canvas.drawPath(
          Path()
            ..moveTo(0, h * 0.32)
            ..lineTo(w, h * 0.32)
            ..lineTo(w * 0.9, h * 0.5)
            ..lineTo(w, h * 0.68)
            ..lineTo(0, h * 0.68)
            ..lineTo(w * 0.1, h * 0.5)
            ..close(),
          fill,
        );
    }
  }

  static Path _starPath(Offset c, double outer, double inner, int points) {
    final path = Path();
    for (var i = 0; i < points * 2; i++) {
      final radius = i.isEven ? outer : inner;
      final angle = -math.pi / 2 + i * math.pi / points;
      final p = Offset(c.dx + radius * math.cos(angle), c.dy + radius * math.sin(angle));
      i == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
    }
    return path..close();
  }

  // ------------------------------------------------------------------- export

  static void _paintTransformed(
    Canvas canvas,
    Size canvasSize,
    LayerTransform t,
    Size content,
    void Function() paintContent,
  ) {
    canvas.save();
    canvas.translate(t.x * canvasSize.width, t.y * canvasSize.height);
    canvas.rotate(t.rotation);
    canvas.scale(t.scale);
    canvas.translate(-content.width / 2, -content.height / 2);
    paintContent();
    canvas.restore();
  }

  /// Renders a text or sticker layer onto a transparent canvas of [size]
  /// and encodes it as PNG, ready to be composited by FFmpeg.
  ///
  /// Logo stickers need [resolveImage] to find their file.
  static Future<Uint8List> rasterize(
    Object layer,
    Size size, {
    String Function(String relativePath)? resolveImage,
  }) async {
    ui.Image? logo;
    if (layer is StickerLayer && layer.sticker.isImage) {
      logo = await _loadImage(resolveImage!(layer.sticker.value as String));
    }
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, Offset.zero & size);
    switch (layer) {
      case final TextLayer text:
        _paintTransformed(
          canvas,
          size,
          text.transform,
          measureText(text, size),
          () => paintTextContent(canvas, text, size),
        );
      case final StickerLayer sticker when logo != null:
        _paintTransformed(
          canvas,
          size,
          sticker.transform,
          stickerBaseSize(size),
          () => paintLogo(canvas, logo!, stickerBaseSize(size), sticker.opacity),
        );
      case final StickerLayer sticker:
        _paintTransformed(
          canvas,
          size,
          sticker.transform,
          stickerBaseSize(size),
          () => paintStickerContent(canvas, sticker, size),
        );
      default:
        throw ArgumentError('Unsupported overlay layer: $layer');
    }
    final picture = recorder.endRecording();
    final image = await picture.toImage(size.width.round(), size.height.round());
    picture.dispose();
    logo?.dispose();
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      return bytes!.buffer.asUint8List();
    } finally {
      image.dispose();
    }
  }
}
