import 'dart:math' as math;

import '../../domain/entities/color_adjustments.dart';
import '../../domain/entities/video_clip.dart';
import '../../domain/entities/video_effect.dart';

/// Builds the colour transform for a clip as a single 4x5 affine matrix
/// (row-major, offsets in 0…255), the same layout as Flutter's
/// `ColorFilter.matrix`.
///
/// Export feeds the identical matrix to FFmpeg's `colorchannelmixer` on RGBA
/// frames, using the constant 255 alpha channel to carry the offset column
/// (`ra = offsetR / 255`). Preview and export therefore apply the same math.
///
/// Highlights/shadows are linear approximations (white/black-point moves),
/// because a single matrix cannot express tone curves.
abstract final class ColorMatrix {
  static const identity = <double>[
    1, 0, 0, 0, 0, //
    0, 1, 0, 0, 0, //
    0, 0, 1, 0, 0, //
    0, 0, 0, 1, 0, //
  ];

  static const _lr = 0.2126, _lg = 0.7152, _lb = 0.0722;

  static List<double> forClip(VideoClip clip) {
    final look = build(clip.filter, clip.filterStrength, clip.adjustments);
    if (clip.effect != VideoEffect.invert) return look;
    // The Invert effect is a colour transform too, so it rides in the same
    // matrix (exact preview).
    return multiply(_lerp(identity, invert, clip.effectIntensity.clamp(0, 1)), look);
  }

  static const invert = <double>[
    -1, 0, 0, 0, 255, //
    0, -1, 0, 0, 255, //
    0, 0, -1, 0, 255, //
    0, 0, 0, 1, 0, //
  ];

  static List<double> build(FilterPreset preset, double strength, ColorAdjustments adjustments) {
    final presetMatrix = _lerp(identity, _preset(preset), strength.clamp(0, 1));
    return multiply(_adjustments(adjustments), presetMatrix);
  }

  static bool isIdentity(List<double> m) {
    for (var i = 0; i < 20; i++) {
      if ((m[i] - identity[i]).abs() > 1e-4) return false;
    }
    return true;
  }

  /// Returns `a ∘ b` (apply [b] first, then [a]).
  static List<double> multiply(List<double> a, List<double> b) {
    final out = List<double>.filled(20, 0);
    for (var row = 0; row < 4; row++) {
      for (var col = 0; col < 5; col++) {
        var sum = col == 4 ? a[row * 5 + 4] : 0.0;
        for (var k = 0; k < 4; k++) {
          sum += a[row * 5 + k] * b[k * 5 + col];
        }
        out[row * 5 + col] = sum;
      }
    }
    return out;
  }

  static List<double> _lerp(List<double> a, List<double> b, double t) =>
      List.generate(20, (i) => a[i] + (b[i] - a[i]) * t);

  static List<double> _gainOffset(double r, double g, double b, [double offset = 0]) => [
    r, 0, 0, 0, offset, //
    0, g, 0, 0, offset, //
    0, 0, b, 0, offset, //
    0, 0, 0, 1, 0, //
  ];

  static List<double> brightness(double v) => _gainOffset(1, 1, 1, v * 0.25 * 255);

  static List<double> exposure(double v) {
    final k = math.pow(2, v).toDouble();
    return _gainOffset(k, k, k);
  }

  static List<double> contrast(double v) {
    final k = 1 + v * 0.6;
    return _gainOffset(k, k, k, 128 * (1 - k));
  }

  static List<double> saturation(double v) {
    final s = (1 + v).clamp(0.0, 3.0);
    final ir = (1 - s) * _lr, ig = (1 - s) * _lg, ib = (1 - s) * _lb;
    return [
      ir + s, ig, ib, 0, 0, //
      ir, ig + s, ib, 0, 0, //
      ir, ig, ib + s, 0, 0, //
      0, 0, 0, 1, 0, //
    ];
  }

  static List<double> temperature(double v) =>
      _gainOffset(1 + 0.12 * v, 1 + 0.02 * v, 1 - 0.12 * v);

  /// Moves the black point: positive lifts shadows, negative crushes them.
  static List<double> shadows(double v) {
    final lift = 0.18 * v;
    final k = 1 - lift;
    return _gainOffset(k, k, k, lift * 255);
  }

  /// Moves the white point: negative recovers highlights, positive boosts.
  static List<double> highlights(double v) {
    final k = 1 + 0.2 * v;
    return _gainOffset(k, k, k);
  }

  static const sepia = <double>[
    0.393, 0.769, 0.189, 0, 0, //
    0.349, 0.686, 0.168, 0, 0, //
    0.272, 0.534, 0.131, 0, 0, //
    0, 0, 0, 1, 0, //
  ];

  static List<double> _preset(FilterPreset preset) => switch (preset) {
    FilterPreset.original => identity,
    FilterPreset.brightness => brightness(0.3),
    FilterPreset.contrast => contrast(0.45),
    FilterPreset.saturation => saturation(0.55),
    FilterPreset.exposure => exposure(0.5),
    FilterPreset.warm => multiply(saturation(0.1), temperature(0.7)),
    FilterPreset.cool => temperature(-0.7),
    FilterPreset.grayscale => saturation(-1),
    FilterPreset.sepia => sepia,
    FilterPreset.vintage => multiply(
      shadows(0.45),
      multiply(contrast(-0.15), _lerp(identity, sepia, 0.55)),
    ),
  };

  static List<double> _adjustments(ColorAdjustments a) {
    var m = identity;
    if (a.exposure != 0) m = multiply(exposure(a.exposure), m);
    if (a.brightness != 0) m = multiply(brightness(a.brightness), m);
    if (a.contrast != 0) m = multiply(contrast(a.contrast), m);
    if (a.highlights != 0) m = multiply(highlights(a.highlights), m);
    if (a.shadows != 0) m = multiply(shadows(a.shadows), m);
    if (a.saturation != 0) m = multiply(saturation(a.saturation), m);
    if (a.temperature != 0) m = multiply(temperature(a.temperature), m);
    return m;
  }
}
