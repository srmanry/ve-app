import 'color_adjustments.dart';
import 'media_info.dart';
import 'transition.dart';
import 'video_effect.dart';

/// Normalised crop rectangle (0…1) in the clip's *displayed* orientation,
/// i.e. after container rotation metadata but before the user's rotate/flip.
class CropRect {
  const CropRect(this.left, this.top, this.width, this.height);

  static const full = CropRect(0, 0, 1, 1);

  final double left;
  final double top;
  final double width;
  final double height;

  bool get isFull => left <= 0 && top <= 0 && width >= 1 && height >= 1;

  @override
  bool operator ==(Object other) =>
      other is CropRect &&
      other.left == left &&
      other.top == top &&
      other.width == width &&
      other.height == height;

  @override
  int get hashCode => Object.hash(left, top, width, height);
}

/// A segment of a source video on the main track.
///
/// Clips on the main track play back-to-back; their position on the
/// timeline is derived from their order (see `ProjectTimeline`).
class VideoClip {
  const VideoClip({
    required this.id,
    required this.sourcePath,
    required this.media,
    required this.trimStart,
    required this.trimEnd,
    this.speed = 1.0,
    this.volume = 1.0,
    this.muted = false,
    this.crop = CropRect.full,
    this.quarterTurns = 0,
    this.flipHorizontal = false,
    this.flipVertical = false,
    this.filter = FilterPreset.original,
    this.filterStrength = 1.0,
    this.adjustments = ColorAdjustments.neutral,
    this.transition = ClipTransition.none,
    this.effect = VideoEffect.none,
    this.effectIntensity = 0.6,
    this.audioDenoise = DenoiseLevel.off,
    this.videoDenoise = DenoiseLevel.off,
  });

  static const speeds = [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0, 4.0];

  /// How long a photo is shown when first added.
  static const defaultStillDuration = Duration(seconds: 3);

  /// A clip covering the whole [media] (videos) or [stillDuration] (photos).
  factory VideoClip.fromMedia({
    required String id,
    required String sourcePath,
    required MediaInfo media,
    Duration stillDuration = defaultStillDuration,
  }) => VideoClip(
    id: id,
    sourcePath: sourcePath,
    media: media,
    trimStart: Duration.zero,
    trimEnd: media.isStillImage ? stillDuration : media.duration,
  );

  final String id;

  /// Path of the source file relative to the app data directory.
  final String sourcePath;
  final MediaInfo media;

  /// Section of the source that is used, in source time.
  final Duration trimStart;
  final Duration trimEnd;

  final double speed;

  /// Linear gain for the original audio (0 … 2).
  final double volume;
  final bool muted;

  final CropRect crop;

  /// Clockwise quarter turns applied by the user (0…3).
  final int quarterTurns;
  final bool flipHorizontal;
  final bool flipVertical;

  final FilterPreset filter;

  /// Blend between original (0) and full preset (1).
  final double filterStrength;
  final ColorAdjustments adjustments;

  /// Transition into the *next* clip.
  final ClipTransition transition;

  final VideoEffect effect;

  /// 0 … 1 strength of [effect].
  final double effectIntensity;

  /// Background-noise removal for the clip's own audio.
  final DenoiseLevel audioDenoise;

  /// Grain/sensor-noise removal for the picture.
  final DenoiseLevel videoDenoise;

  /// Length of the used source section.
  Duration get sourceDuration => trimEnd - trimStart;

  /// Length on the timeline after applying [speed].
  Duration get duration => Duration(microseconds: (sourceDuration.inMicroseconds / speed).round());

  /// True for photo clips.
  bool get isStill => media.isStillImage;

  bool get hasAudibleAudio => media.hasAudio && !muted && volume > 0;

  bool get hasColorChanges =>
      (filter != FilterPreset.original && filterStrength > 0) || !adjustments.isNeutral;

  bool get hasGeometryChanges =>
      !crop.isFull || quarterTurns % 4 != 0 || flipHorizontal || flipVertical;

  /// Displayed width/height ratio after crop and rotation.
  double get outputAspectRatio {
    final w = media.displayWidth * crop.width;
    final h = media.displayHeight * crop.height;
    if (w <= 0 || h <= 0) return media.aspectRatio;
    return quarterTurns.isOdd ? h / w : w / h;
  }

  /// Converts a source position into the timeline offset from this clip's
  /// start (and vice versa).
  Duration sourceToLocal(Duration source) =>
      Duration(microseconds: ((source - trimStart).inMicroseconds / speed).round());

  Duration localToSource(Duration local) =>
      trimStart + Duration(microseconds: (local.inMicroseconds * speed).round());

  VideoClip copyWith({
    String? id,
    String? sourcePath,
    MediaInfo? media,
    Duration? trimStart,
    Duration? trimEnd,
    double? speed,
    double? volume,
    bool? muted,
    CropRect? crop,
    int? quarterTurns,
    bool? flipHorizontal,
    bool? flipVertical,
    FilterPreset? filter,
    double? filterStrength,
    ColorAdjustments? adjustments,
    ClipTransition? transition,
    VideoEffect? effect,
    double? effectIntensity,
    DenoiseLevel? audioDenoise,
    DenoiseLevel? videoDenoise,
  }) => VideoClip(
    id: id ?? this.id,
    sourcePath: sourcePath ?? this.sourcePath,
    media: media ?? this.media,
    trimStart: trimStart ?? this.trimStart,
    trimEnd: trimEnd ?? this.trimEnd,
    speed: speed ?? this.speed,
    volume: volume ?? this.volume,
    muted: muted ?? this.muted,
    crop: crop ?? this.crop,
    quarterTurns: quarterTurns ?? this.quarterTurns,
    flipHorizontal: flipHorizontal ?? this.flipHorizontal,
    flipVertical: flipVertical ?? this.flipVertical,
    filter: filter ?? this.filter,
    filterStrength: filterStrength ?? this.filterStrength,
    adjustments: adjustments ?? this.adjustments,
    transition: transition ?? this.transition,
    effect: effect ?? this.effect,
    effectIntensity: effectIntensity ?? this.effectIntensity,
    audioDenoise: audioDenoise ?? this.audioDenoise,
    videoDenoise: videoDenoise ?? this.videoDenoise,
  );
}
