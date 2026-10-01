/// Settings shared by the audio tools (cut, convert, merge, mix, clean…).
///
/// Pure data; `AudioCommandBuilder` turns them into FFmpeg filter graphs.
library;

/// Encoder bitrate for MP3 / M4A output.
enum AudioQuality {
  kbps64(64, 'Tiny'),
  kbps96(96, 'Small'),
  kbps128(128, 'Standard'),
  kbps192(192, 'High'),
  kbps256(256, 'Very high'),
  kbps320(320, 'Best');

  const AudioQuality(this.kbps, this.hint);
  final int kbps;
  final String hint;

  String get label => '$kbps kbps';

  /// Shown in format pickers (64 kbps is only used by Compress).
  static List<AudioQuality> get selectable => values.where((q) => q.kbps >= 96).toList();
}

/// Presets of the Compress tool (always MP3).
enum AudioCompression {
  light('Light', 'Good quality', AudioQuality.kbps128, mono: false),
  medium('Medium', 'Smaller file', AudioQuality.kbps96, mono: false),
  strong('Strong', 'Smallest, mono', AudioQuality.kbps64, mono: true);

  const AudioCompression(this.label, this.hint, this.quality, {required this.mono});
  final String label;
  final String hint;
  final AudioQuality quality;
  final bool mono;

  int get kbps => quality.kbps;

  /// Rough output size for [duration].
  int estimatedBytes(Duration duration) => duration.inMilliseconds * kbps ~/ 8;
}

/// What the Clean tool removes.
///
/// These are signal filters, not AI source separation: they subtract a
/// measured noise profile, keep only the speech band, or cancel what both
/// stereo channels share (where lead vocals are usually mixed).
enum CleanupMode {
  backgroundNoise('Background noise', 'Hiss, hum, fan and room noise'),
  voiceFocus('Voice focus', 'Keeps the speech range, drops the rest'),
  removeVocals('Remove vocals', 'Karaoke: cancels centre vocals (stereo songs)');

  const CleanupMode(this.label, this.hint);
  final String label;
  final String hint;

  bool get hasStrength => this != removeVocals;
}

/// Strength of the adaptive denoiser (`afftdn`).
enum NoiseStrength {
  light('Light', reductionDb: 6, floorDb: -35),
  medium('Medium', reductionDb: 12, floorDb: -28),
  strong('Strong', reductionDb: 24, floorDb: -20);

  const NoiseStrength(this.label, {required this.reductionDb, required this.floorDb});
  final String label;
  final int reductionDb;
  final int floorDb;
}

class CleanupSettings {
  const CleanupSettings(this.mode, [this.strength = NoiseStrength.medium]);
  final CleanupMode mode;
  final NoiseStrength strength;
}

/// Speeds offered for audio (pitch is preserved).
const audioSpeeds = <double>[0.5, 0.75, 1.0, 1.25, 1.5, 2.0];

/// How long a mix lasts.
enum MixLength {
  main('Main track', 'first'),
  longest('Longest track', 'longest');

  const MixLength(this.label, this.ffmpegValue);
  final String label;
  final String ffmpegValue;
}

/// One point of a [VolumeEnvelope].
class EnvelopePoint {
  const EnvelopePoint(this.position, this.level);

  /// 0 … 1 across the used part of the track.
  final double position;

  /// 0 … 2 (1 = unchanged).
  final double level;
}

/// Volume shape over a track. Between two points the level eases along an
/// S-curve, so fades sound natural.
enum VolumeEnvelope {
  flat('Flat', [EnvelopePoint(0, 1), EnvelopePoint(1, 1)]),
  fadeIn('Fade in', [EnvelopePoint(0, 0), EnvelopePoint(0.15, 1), EnvelopePoint(1, 1)]),
  fadeOut('Fade out', [EnvelopePoint(0, 1), EnvelopePoint(0.85, 1), EnvelopePoint(1, 0)]),
  fadeInOut('Fade in & out', [
    EnvelopePoint(0, 0),
    EnvelopePoint(0.1, 1),
    EnvelopePoint(0.9, 1),
    EnvelopePoint(1, 0),
  ]),
  dip('Dip in middle', [
    EnvelopePoint(0, 1),
    EnvelopePoint(0.3, 1),
    EnvelopePoint(0.4, 0.3),
    EnvelopePoint(0.6, 0.3),
    EnvelopePoint(0.7, 1),
    EnvelopePoint(1, 1),
  ]);

  const VolumeEnvelope(this.label, this.points);
  final String label;
  final List<EnvelopePoint> points;

  /// Level at [position] (0 … 1), matching what FFmpeg renders.
  double levelAt(double position) {
    final x = position.clamp(0.0, 1.0);
    for (var i = 0; i < points.length - 1; i++) {
      final a = points[i], b = points[i + 1];
      if (x <= b.position || i == points.length - 2) {
        final span = b.position - a.position;
        if (span <= 0) return b.level;
        final t = ((x - a.position) / span).clamp(0.0, 1.0);
        return a.level + (b.level - a.level) * t * t * (3 - 2 * t);
      }
    }
    return points.last.level;
  }
}

/// One layer of the Mix tool.
class MixTrack {
  const MixTrack({
    required this.path,
    required this.name,
    required this.sourceDuration,
    this.volume = 1.0,
    this.start = Duration.zero,
    this.trimStart = Duration.zero,
    this.trimEnd,
    this.envelope = VolumeEnvelope.flat,
  });

  /// Absolute path of the source file.
  final String path;
  final String name;
  final Duration sourceDuration;

  /// 0 … 2.
  final double volume;

  /// Where the track begins on the mix timeline.
  final Duration start;
  final Duration trimStart;

  /// null = until the end of the source.
  final Duration? trimEnd;
  final VolumeEnvelope envelope;

  Duration get usedEnd =>
      trimEnd == null || trimEnd! > sourceDuration ? sourceDuration : trimEnd!;

  /// Length of the used part.
  Duration get usedLength {
    final d = usedEnd - trimStart;
    return d.isNegative ? Duration.zero : d;
  }

  bool get isTrimmed => trimStart > Duration.zero || usedEnd < sourceDuration;

  Duration get end => start + usedLength;

  MixTrack copyWith({
    double? volume,
    Duration? start,
    Duration? trimStart,
    Duration? trimEnd,
    VolumeEnvelope? envelope,
  }) => MixTrack(
    path: path,
    name: name,
    sourceDuration: sourceDuration,
    volume: volume ?? this.volume,
    start: start ?? this.start,
    trimStart: trimStart ?? this.trimStart,
    trimEnd: trimEnd ?? this.trimEnd,
    envelope: envelope ?? this.envelope,
  );
}
