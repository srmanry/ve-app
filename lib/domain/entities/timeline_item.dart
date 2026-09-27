/// Anything placed on a secondary timeline track (audio, text, sticker, PIP).
abstract interface class TimelineItem {
  String get id;

  /// Where the item starts on the project timeline.
  Duration get start;

  /// How long it is visible/audible on the timeline.
  Duration get duration;
}

extension TimelineItemX on TimelineItem {
  Duration get end => start + duration;

  bool isActiveAt(Duration t) => t >= start && t < end;
}
