import 'layer_transform.dart';
import 'media_info.dart';
import 'timeline_item.dart';

/// A picture-in-picture video drawn above the main track.
class PipLayer implements TimelineItem {
  const PipLayer({
    required this.id,
    required this.sourcePath,
    required this.media,
    required this.start,
    required this.trimStart,
    required this.trimEnd,
    this.transform = const LayerTransform(x: 0.72, y: 0.28, scale: 0.4),
    this.volume = 1.0,
    this.muted = false,
  });

  @override
  final String id;
  final String sourcePath;
  final MediaInfo media;

  @override
  final Duration start;
  final Duration trimStart;
  final Duration trimEnd;

  /// [LayerTransform.scale] is the overlay width as a fraction of the canvas
  /// width (height follows the source aspect ratio).
  final LayerTransform transform;
  final double volume;
  final bool muted;

  @override
  Duration get duration => trimEnd - trimStart;

  bool get hasAudibleAudio => media.hasAudio && !muted && volume > 0;

  PipLayer copyWith({
    Duration? start,
    Duration? trimStart,
    Duration? trimEnd,
    LayerTransform? transform,
    double? volume,
    bool? muted,
  }) => PipLayer(
    id: id,
    sourcePath: sourcePath,
    media: media,
    start: start ?? this.start,
    trimStart: trimStart ?? this.trimStart,
    trimEnd: trimEnd ?? this.trimEnd,
    transform: transform ?? this.transform,
    volume: volume ?? this.volume,
    muted: muted ?? this.muted,
  );
}
