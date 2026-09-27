import 'dart:math' as math;

import 'export_settings.dart';
import 'project.dart';
import 'video_clip.dart';

/// Where a timeline position falls on the main track.
class ClipPosition {
  const ClipPosition(this.index, this.clip, this.clipStart, this.local);

  final int index;
  final VideoClip clip;

  /// Timeline position where [clip] starts.
  final Duration clipStart;

  /// Offset into the clip, in timeline time (speed already applied).
  final Duration local;

  /// Corresponding position in the source file.
  Duration get sourcePosition => clip.localToSource(local);
}

/// A transition in progress at some timeline position.
class ActiveTransition {
  const ActiveTransition(this.fromIndex, this.progress);

  /// Index of the outgoing clip.
  final int fromIndex;

  /// 0 … 1 through the transition.
  final double progress;
}

/// Pure timeline math shared by the preview, the timeline UI and the export
/// command builder, so all three agree on where every clip sits.
///
/// With transitions, consecutive clips overlap by the transition length:
///
/// ```
/// clip 0 |==========|
/// clip 1        |~~~~==========|      (~~~ = xfade overlap)
///               ^ start(1) = start(0) + d0 - t0
/// ```
class ProjectTimeline {
  ProjectTimeline(this.project) {
    final clips = project.clips;
    _starts = List.filled(clips.length, Duration.zero);
    _transitions = List.filled(clips.length, Duration.zero);
    var cursor = Duration.zero;
    for (var i = 0; i < clips.length; i++) {
      _starts[i] = cursor;
      _transitions[i] = _effectiveTransition(i);
      cursor += clips[i].duration - _transitions[i];
    }
    // The last clip has no outgoing transition, so cursor == end of track.
    duration = cursor;
  }

  final Project project;
  late final List<Duration> _starts;
  late final List<Duration> _transitions;

  /// Length of the main track, which is the length of the exported video.
  late final Duration duration;

  List<VideoClip> get clips => project.clips;

  Duration clipStart(int index) => _starts[index];
  Duration clipEnd(int index) => _starts[index] + clips[index].duration;

  /// Effective (clamped) duration of the transition after clip [index].
  Duration transitionAfter(int index) => _transitions[index];

  /// Transitions are clamped to half of each neighbouring clip, which
  /// guarantees that incoming and outgoing transitions of a clip never
  /// overlap each other and that every FFmpeg `xfade` offset is valid.
  Duration _effectiveTransition(int index) {
    final clips = project.clips;
    if (index >= clips.length - 1) return Duration.zero;
    final t = clips[index].transition;
    if (t.isNone) return Duration.zero;
    final limit =
        math.min(clips[index].duration.inMilliseconds, clips[index + 1].duration.inMilliseconds) ~/
        2;
    return Duration(milliseconds: math.min(t.duration.inMilliseconds, limit));
  }

  /// Finds the clip visible at [t]. Inside a transition overlap, the
  /// outgoing clip is reported for the first half and the incoming one for
  /// the second half.
  ClipPosition? locate(Duration t) {
    if (clips.isEmpty) return null;
    if (t < Duration.zero) t = Duration.zero;
    for (var i = 0; i < clips.length; i++) {
      final isLast = i == clips.length - 1;
      final switchPoint = isLast ? clipEnd(i) : _starts[i + 1] + _transitions[i] ~/ 2;
      if (t < switchPoint || isLast) {
        final local = t - _starts[i];
        final clamped = local > clips[i].duration ? clips[i].duration : local;
        return ClipPosition(i, clips[i], _starts[i], clamped);
      }
    }
    return null;
  }

  /// Index of the clip that is "under" [t] for editing purposes
  /// (e.g. split), ignoring overlaps.
  int? clipIndexAt(Duration t) => locate(t)?.index;

  ActiveTransition? transitionAt(Duration t) {
    for (var i = 0; i < clips.length - 1; i++) {
      final len = _transitions[i];
      if (len == Duration.zero) continue;
      final from = _starts[i + 1];
      if (t >= from && t < from + len) {
        return ActiveTransition(i, (t - from).inMicroseconds / len.inMicroseconds);
      }
    }
    return null;
  }

  /// Aspect ratio (w/h) of the canvas.
  double get canvasAspectRatio =>
      project.canvas.aspectRatio.ratio ?? (clips.isEmpty ? 16 / 9 : clips.first.outputAspectRatio);

  /// Output frame size for [settings]; always even (required by H.264/yuv420p).
  ({int width, int height}) outputSize(ExportSettings settings) {
    final aspect = canvasAspectRatio;
    int shortSide;
    if (settings.resolution.shortSide != null) {
      shortSide = settings.resolution.shortSide!;
    } else if (clips.isNotEmpty) {
      final c = clips.first;
      final w = c.media.displayWidth * c.crop.width;
      final h = c.media.displayHeight * c.crop.height;
      shortSide = math.min(w, h).round();
    } else {
      shortSide = 1080;
    }
    shortSide = shortSide.clamp(144, 2160);
    double w, h;
    if (aspect >= 1) {
      h = shortSide.toDouble();
      w = h * aspect;
    } else {
      w = shortSide.toDouble();
      h = w / aspect;
    }
    // Keep within 4K on the long edge.
    final longSide = math.max(w, h);
    if (longSide > 3840) {
      final k = 3840 / longSide;
      w *= k;
      h *= k;
    }
    int even(double v) => math.max(2, (v / 2).round() * 2);
    return (width: even(w), height: even(h));
  }

  /// Rough size estimate (bytes) for an export with [settings].
  int estimateOutputBytes(ExportSettings settings) {
    final size = outputSize(settings);
    final kbps = settings.videoBitrateKbps(size.width, size.height) + settings.audioBitrateKbps;
    final seconds = duration.inMilliseconds / 1000;
    // ~3% container overhead.
    return (kbps * 1000 / 8 * seconds * 1.03).round();
  }
}
