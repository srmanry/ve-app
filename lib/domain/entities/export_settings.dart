import 'canvas_settings.dart';

enum ExportResolution {
  p480('480p', 480),
  p720('720p', 720),
  p1080('1080p', 1080),
  original('Original', null);

  const ExportResolution(this.label, this.shortSide);
  final String label;

  /// Length of the shorter output edge, or null to keep the source size.
  final int? shortSide;
}

enum ExportQuality {
  low('Low', 0.045),
  medium('Medium', 0.075),
  high('High', 0.12),
  custom('Custom', 0.075);

  const ExportQuality(this.label, this.bitsPerPixel);
  final String label;

  /// Video bits per pixel per frame used to derive a target bitrate.
  final double bitsPerPixel;
}

/// Output container. Only MP4 (H.264 + AAC) for now - the most compatible
/// choice for sharing; kept as an enum so more can be added later.
enum ExportFormat { mp4 }

/// Where the video is going. Picking a target fills in the frame shape,
/// resolution, frame rate and quality that platform expects; every value
/// can still be changed afterwards.
enum ExportTarget {
  /// Keep the project's own shape ("full" frame).
  original('Original', null, ExportResolution.p1080, 30, ExportQuality.high),
  youtube(
    'YouTube',
    AspectRatioPreset.landscape16x9,
    ExportResolution.p1080,
    30,
    ExportQuality.high,
  ),
  youtubeShorts(
    'YouTube Shorts',
    AspectRatioPreset.portrait9x16,
    ExportResolution.p1080,
    30,
    ExportQuality.high,
  ),
  facebook(
    'Facebook',
    AspectRatioPreset.portrait4x5,
    ExportResolution.p1080,
    30,
    ExportQuality.high,
  ),
  facebookReels(
    'Facebook Reels',
    AspectRatioPreset.portrait9x16,
    ExportResolution.p1080,
    30,
    ExportQuality.high,
  ),
  instagramReels(
    'Instagram Reels',
    AspectRatioPreset.portrait9x16,
    ExportResolution.p1080,
    30,
    ExportQuality.high,
  ),
  instagramPost(
    'Instagram Post',
    AspectRatioPreset.portrait4x5,
    ExportResolution.p1080,
    30,
    ExportQuality.high,
  ),
  tiktok('TikTok', AspectRatioPreset.portrait9x16, ExportResolution.p1080, 30, ExportQuality.high),
  // WhatsApp re-compresses anyway; a smaller file sends faster.
  whatsappStatus(
    'WhatsApp Status',
    AspectRatioPreset.portrait9x16,
    ExportResolution.p720,
    30,
    ExportQuality.medium,
  ),
  twitter(
    'X (Twitter)',
    AspectRatioPreset.landscape16x9,
    ExportResolution.p720,
    30,
    ExportQuality.high,
  ),

  /// Choose the shape and everything else by hand.
  custom('Custom', null, ExportResolution.p1080, 30, ExportQuality.high);

  const ExportTarget(this.label, this.aspectRatio, this.resolution, this.frameRate, this.quality);

  final String label;

  /// Frame shape the platform expects, or null to keep the current one.
  final AspectRatioPreset? aspectRatio;
  final ExportResolution resolution;
  final int frameRate;
  final ExportQuality quality;
}

const _keep = Object();

class ExportSettings {
  const ExportSettings({
    this.resolution = ExportResolution.p1080,
    this.frameRate = 30,
    this.quality = ExportQuality.high,
    this.customBitrateKbps = 8000,
    this.format = ExportFormat.mp4,
    this.audioBitrateKbps = 128,
    this.target = ExportTarget.original,
    this.aspectRatio,
    this.fit,
  });

  static const frameRates = [24, 30, 60];

  final ExportResolution resolution;
  final int frameRate;
  final ExportQuality quality;

  /// Video bitrate used when [quality] is [ExportQuality.custom].
  final int customBitrateKbps;
  final ExportFormat format;
  final int audioBitrateKbps;

  /// Last platform preset picked (for display; values below are what count).
  final ExportTarget target;

  /// Frame shape for this export; null keeps the project's canvas.
  final AspectRatioPreset? aspectRatio;

  /// Fit/fill for this export; null keeps the project's canvas setting.
  final CanvasFit? fit;

  /// The canvas actually rendered: the project's, with this export's
  /// shape/fit overrides. The project itself is never changed.
  CanvasSettings canvasFor(CanvasSettings projectCanvas) => projectCanvas.copyWith(
    aspectRatio: aspectRatio ?? projectCanvas.aspectRatio,
    fit: fit ?? projectCanvas.fit,
  );

  /// Applies a platform preset. [custom] keeps the current values.
  ExportSettings withTarget(ExportTarget t) => t == ExportTarget.custom
      ? copyWith(target: t)
      : copyWith(
          target: t,
          aspectRatio: t.aspectRatio,
          resolution: t.resolution,
          frameRate: t.frameRate,
          quality: t.quality,
          // "Original" means the project's own framing, fit included.
          fit: t.aspectRatio == null ? null : fit,
        );

  /// Target video bitrate for an output of [width]x[height].
  int videoBitrateKbps(int width, int height) {
    if (quality == ExportQuality.custom) return customBitrateKbps;
    final bps = width * height * frameRate * quality.bitsPerPixel;
    return (bps / 1000).round().clamp(300, 60000);
  }

  ExportSettings copyWith({
    ExportResolution? resolution,
    int? frameRate,
    ExportQuality? quality,
    int? customBitrateKbps,
    int? audioBitrateKbps,
    ExportTarget? target,
    Object? aspectRatio = _keep,
    Object? fit = _keep,
  }) => ExportSettings(
    resolution: resolution ?? this.resolution,
    frameRate: frameRate ?? this.frameRate,
    quality: quality ?? this.quality,
    customBitrateKbps: customBitrateKbps ?? this.customBitrateKbps,
    format: format,
    audioBitrateKbps: audioBitrateKbps ?? this.audioBitrateKbps,
    target: target ?? this.target,
    aspectRatio: identical(aspectRatio, _keep)
        ? this.aspectRatio
        : aspectRatio as AspectRatioPreset?,
    fit: identical(fit, _keep) ? this.fit : fit as CanvasFit?,
  );
}

/// Compression tool presets (section 18).
enum CompressionPreset {
  high(
    'High quality',
    ExportSettings(resolution: ExportResolution.original, quality: ExportQuality.high),
  ),
  medium(
    'Medium quality',
    ExportSettings(resolution: ExportResolution.p720, quality: ExportQuality.medium),
  ),
  small(
    'Small size',
    ExportSettings(
      resolution: ExportResolution.p480,
      quality: ExportQuality.low,
      audioBitrateKbps: 96,
    ),
  ),
  custom(
    'Custom',
    ExportSettings(
      resolution: ExportResolution.p720,
      quality: ExportQuality.custom,
      customBitrateKbps: 2500,
    ),
  );

  const CompressionPreset(this.label, this.settings);
  final String label;
  final ExportSettings settings;
}
