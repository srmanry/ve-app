/// Placement of an overlay (text, sticker, picture-in-picture) on the canvas.
///
/// Coordinates are resolution-independent so the same project renders
/// identically in the small preview and in a 1080p export.
class LayerTransform {
  const LayerTransform({this.x = 0.5, this.y = 0.5, this.scale = 1.0, this.rotation = 0.0});

  /// Centre of the layer as a fraction of canvas width/height (0…1).
  final double x;
  final double y;

  /// Uniform scale factor relative to the layer's base size.
  final double scale;

  /// Clockwise rotation in radians.
  final double rotation;

  LayerTransform copyWith({double? x, double? y, double? scale, double? rotation}) =>
      LayerTransform(
        x: x ?? this.x,
        y: y ?? this.y,
        scale: scale ?? this.scale,
        rotation: rotation ?? this.rotation,
      );

  @override
  bool operator ==(Object other) =>
      other is LayerTransform &&
      other.x == x &&
      other.y == y &&
      other.scale == scale &&
      other.rotation == rotation;

  @override
  int get hashCode => Object.hash(x, y, scale, rotation);
}
