/// Look presets. The actual colour math lives in `ColorMatrixBuilder`, which
/// produces one affine matrix used both by the live preview
/// (`ColorFilter.matrix`) and by export (`colorchannelmixer`), so what the
/// user sees is what they get.
enum FilterPreset {
  original('Original'),
  brightness('Bright'),
  contrast('Contrast'),
  saturation('Vivid'),
  exposure('Exposure'),
  warm('Warm'),
  cool('Cool'),
  grayscale('Mono'),
  vintage('Vintage'),
  sepia('Sepia');

  const FilterPreset(this.label);
  final String label;
}

/// Manual adjustment sliders, each normalised to -1.0 … 1.0 (0 = neutral).
class ColorAdjustments {
  const ColorAdjustments({
    this.brightness = 0,
    this.contrast = 0,
    this.saturation = 0,
    this.exposure = 0,
    this.temperature = 0,
    this.highlights = 0,
    this.shadows = 0,
  });

  static const neutral = ColorAdjustments();

  final double brightness;
  final double contrast;
  final double saturation;
  final double exposure;
  final double temperature;
  final double highlights;
  final double shadows;

  bool get isNeutral =>
      brightness == 0 &&
      contrast == 0 &&
      saturation == 0 &&
      exposure == 0 &&
      temperature == 0 &&
      highlights == 0 &&
      shadows == 0;

  ColorAdjustments copyWith({
    double? brightness,
    double? contrast,
    double? saturation,
    double? exposure,
    double? temperature,
    double? highlights,
    double? shadows,
  }) => ColorAdjustments(
    brightness: brightness ?? this.brightness,
    contrast: contrast ?? this.contrast,
    saturation: saturation ?? this.saturation,
    exposure: exposure ?? this.exposure,
    temperature: temperature ?? this.temperature,
    highlights: highlights ?? this.highlights,
    shadows: shadows ?? this.shadows,
  );

  @override
  bool operator ==(Object other) =>
      other is ColorAdjustments &&
      other.brightness == brightness &&
      other.contrast == contrast &&
      other.saturation == saturation &&
      other.exposure == exposure &&
      other.temperature == temperature &&
      other.highlights == highlights &&
      other.shadows == shadows;

  @override
  int get hashCode =>
      Object.hash(brightness, contrast, saturation, exposure, temperature, highlights, shadows);
}
