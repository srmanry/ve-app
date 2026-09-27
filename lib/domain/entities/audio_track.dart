import 'media_info.dart';
import 'timeline_item.dart';

/// An additional audio layer: background music, extracted audio, etc.
class AudioTrack implements TimelineItem {
  const AudioTrack({
    required this.id,
    required this.name,
    required this.sourcePath,
    required this.media,
    required this.start,
    required this.trimStart,
    required this.trimEnd,
    this.volume = 1.0,
    this.muted = false,
  });

  @override
  final String id;
  final String name;

  /// Path relative to the app data directory.
  final String sourcePath;
  final MediaInfo media;

  /// Position on the timeline.
  @override
  final Duration start;

  /// Used section of the source audio.
  final Duration trimStart;
  final Duration trimEnd;

  /// Linear gain (0 … 2).
  final double volume;
  final bool muted;

  @override
  Duration get duration => trimEnd - trimStart;

  AudioTrack copyWith({
    String? name,
    Duration? start,
    Duration? trimStart,
    Duration? trimEnd,
    double? volume,
    bool? muted,
  }) => AudioTrack(
    id: id,
    name: name ?? this.name,
    sourcePath: sourcePath,
    media: media,
    start: start ?? this.start,
    trimStart: trimStart ?? this.trimStart,
    trimEnd: trimEnd ?? this.trimEnd,
    volume: volume ?? this.volume,
    muted: muted ?? this.muted,
  );
}
