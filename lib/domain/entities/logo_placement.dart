import 'dart:math' as math;

import 'layer_transform.dart';
import 'sticker_layer.dart';

/// Quick positions for a logo/watermark. It can also be dragged anywhere.
enum LogoPosition {
  topLeft('Top left'),
  topRight('Top right'),
  bottomLeft('Bottom left'),
  bottomRight('Bottom right'),
  center('Center');

  const LogoPosition(this.label);
  final String label;
}

/// Places logo stickers consistently in the editor, camera and export.
abstract final class LogoPlacement {
  static const defaultScale = 0.7;
  static const defaultOpacity = 0.9;

  /// Distance from the frame edge, as a fraction of each dimension.
  static const margin = 0.03;

  /// Transform that puts a logo box (sticker box: 20% of the canvas' short
  /// side × [scale]) at [position] on a canvas of [aspect] (w/h).
  static LayerTransform transformFor(LogoPosition position, double scale, double aspect) {
    final shortSide = math.min(aspect, 1.0); // in units where height = 1
    final halfH = 0.1 * shortSide * scale;
    final halfW = halfH / aspect;
    final left = margin + halfW, right = 1 - margin - halfW;
    final top = margin + halfH, bottom = 1 - margin - halfH;
    final (x, y) = switch (position) {
      LogoPosition.topLeft => (left, top),
      LogoPosition.topRight => (right, top),
      LogoPosition.bottomLeft => (left, bottom),
      LogoPosition.bottomRight => (right, bottom),
      LogoPosition.center => (0.5, 0.5),
    };
    return LayerTransform(x: x, y: y, scale: scale);
  }

  /// A logo layer covering the whole video.
  static StickerLayer layer({
    required String id,
    required String logoPath,
    required Duration duration,
    required double canvasAspect,
    LogoPosition position = LogoPosition.topRight,
    double scale = defaultScale,
    double opacity = defaultOpacity,
    Duration start = Duration.zero,
  }) => StickerLayer(
    id: id,
    sticker: StickerSpec.image(logoPath),
    start: start,
    duration: duration,
    transform: transformFor(position, scale, canvasAspect),
    opacity: opacity,
  );
}

/// Logo chosen in the camera, applied as a layer over the recorded takes.
class CameraLogo {
  const CameraLogo({
    required this.path,
    this.position = LogoPosition.topRight,
    this.scale = LogoPlacement.defaultScale,
    this.opacity = LogoPlacement.defaultOpacity,
  });

  /// Relative path of the logo PNG.
  final String path;
  final LogoPosition position;
  final double scale;
  final double opacity;

  CameraLogo copyWith({LogoPosition? position, double? scale, double? opacity}) => CameraLogo(
    path: path,
    position: position ?? this.position,
    scale: scale ?? this.scale,
    opacity: opacity ?? this.opacity,
  );
}
