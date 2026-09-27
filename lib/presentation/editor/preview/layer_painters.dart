import 'package:flutter/widgets.dart';

import '../../../domain/entities/sticker_layer.dart';
import '../../../domain/entities/text_layer.dart';
import '../../../services/overlay/overlay_painter.dart';

/// Preview painters delegating to [OverlayPainter], the same code used to
/// rasterise overlays for export.
class TextLayerPainter extends CustomPainter {
  TextLayerPainter(this.layer, this.canvasSize);
  final TextLayer layer;
  final Size canvasSize;

  @override
  void paint(Canvas canvas, Size size) =>
      OverlayPainter.paintTextContent(canvas, layer, canvasSize);

  @override
  bool shouldRepaint(TextLayerPainter old) => old.layer != layer || old.canvasSize != canvasSize;
}

class StickerLayerPainter extends CustomPainter {
  StickerLayerPainter(this.layer, this.canvasSize);
  final StickerLayer layer;
  final Size canvasSize;

  @override
  void paint(Canvas canvas, Size size) =>
      OverlayPainter.paintStickerContent(canvas, layer, canvasSize);

  @override
  bool shouldRepaint(StickerLayerPainter old) => old.layer != layer || old.canvasSize != canvasSize;
}

class StickerSpecPainter extends CustomPainter {
  StickerSpecPainter(this.sticker);
  final StickerSpec sticker;

  @override
  void paint(Canvas canvas, Size size) => OverlayPainter.paintSticker(canvas, sticker, size);

  @override
  bool shouldRepaint(StickerSpecPainter old) =>
      old.sticker.value != sticker.value || old.sticker.color != sticker.color;
}
