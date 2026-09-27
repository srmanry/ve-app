enum TransitionType {
  none('None', null),
  fade('Fade', 'fade'),
  crossDissolve('Dissolve', 'dissolve'),
  slide('Slide', 'slideleft'),
  zoom('Zoom', 'zoomin');

  const TransitionType(this.label, this.xfadeName);
  final String label;

  /// Name of the FFmpeg `xfade` transition, or null for a hard cut.
  final String? xfadeName;
}

/// Transition from one clip into the next one on the main track.
class ClipTransition {
  const ClipTransition({
    this.type = TransitionType.none,
    this.duration = const Duration(milliseconds: 1000),
  });

  static const none = ClipTransition();

  static const durations = [
    Duration(milliseconds: 500),
    Duration(milliseconds: 1000),
    Duration(milliseconds: 1500),
    Duration(milliseconds: 2000),
  ];

  final TransitionType type;
  final Duration duration;

  bool get isNone => type == TransitionType.none;

  ClipTransition copyWith({TransitionType? type, Duration? duration}) =>
      ClipTransition(type: type ?? this.type, duration: duration ?? this.duration);

  @override
  bool operator ==(Object other) =>
      other is ClipTransition && other.type == type && other.duration == duration;

  @override
  int get hashCode => Object.hash(type, duration);
}
