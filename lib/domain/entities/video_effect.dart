/// Creative effects applied to a whole clip (one per clip, with intensity).
///
/// Rendered exactly by FFmpeg at export; the editor shows a live preview
/// where the effect can be reproduced with Flutter (see `ClipEffectView`).
enum VideoEffect {
  none('None', livePreview: true),
  blur('Blur', livePreview: true),
  vignette('Vignette', livePreview: true),
  mirror('Mirror', livePreview: true),
  invert('Invert', livePreview: true),
  glitch('Glitch', livePreview: true),
  grain('Film grain', livePreview: true),
  pixelate('Pixelate', livePreview: true),
  sharpen('Sharpen', livePreview: false);

  const VideoEffect(this.label, {required this.livePreview});
  final String label;

  /// False when the preview can't show the effect (it still exports).
  final bool livePreview;
}

/// Noise reduction strength.
enum DenoiseLevel {
  off('Off'),
  light('Light'),
  medium('Medium'),
  strong('Strong');

  const DenoiseLevel(this.label);
  final String label;
}
