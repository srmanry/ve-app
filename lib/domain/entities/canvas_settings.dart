enum AspectRatioPreset {
  original('Original', null),
  landscape16x9('16:9', 16 / 9),
  portrait9x16('9:16', 9 / 16),
  square1x1('1:1', 1.0),
  portrait4x5('4:5', 4 / 5),
  landscape4x3('4:3', 4 / 3);

  const AspectRatioPreset(this.label, this.ratio);
  final String label;

  /// Width / height, or null for "use the first clip's aspect ratio".
  final double? ratio;
}

/// How clips whose shape differs from the canvas are placed on it.
enum CanvasFit {
  /// Whole frame visible, bars filled with [CanvasSettings.backgroundColor].
  fit('Fit'),

  /// Frame scaled to cover the canvas; edges are cropped.
  fill('Fill');

  const CanvasFit(this.label);
  final String label;
}

class CanvasSettings {
  const CanvasSettings({
    this.aspectRatio = AspectRatioPreset.original,
    this.fit = CanvasFit.fit,
    this.backgroundColor = 0xFF000000,
  });

  final AspectRatioPreset aspectRatio;
  final CanvasFit fit;

  /// ARGB colour of letterbox/pillarbox bars.
  final int backgroundColor;

  CanvasSettings copyWith({AspectRatioPreset? aspectRatio, CanvasFit? fit, int? backgroundColor}) =>
      CanvasSettings(
        aspectRatio: aspectRatio ?? this.aspectRatio,
        fit: fit ?? this.fit,
        backgroundColor: backgroundColor ?? this.backgroundColor,
      );
}
