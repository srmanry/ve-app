import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../../../domain/entities/project.dart';
import '../../../domain/entities/project_timeline.dart';
import '../../../domain/entities/timeline_item.dart';
import '../../../domain/entities/video_clip.dart';
import '../editor_scope.dart';
import '../playback/playback_controller.dart';
import '../state/editor_controller.dart';
import '../state/editor_state.dart';
import 'timeline_layer_lane.dart';
import 'timeline_ruler.dart';
import 'timeline_thumbnails.dart';

/// Multi-track timeline with a fixed centre playhead: scrolling the
/// timeline scrubs the video; during playback the timeline follows.
///
/// Only the visible part of each track is built, so hour-long projects stay
/// smooth.
class TimelineView extends ConsumerStatefulWidget {
  const TimelineView({super.key, required this.onAddClip});

  final VoidCallback onAddClip;

  @override
  ConsumerState<TimelineView> createState() => _TimelineViewState();
}

class _TimelineViewState extends ConsumerState<TimelineView> {
  static const rulerHeight = 22.0;
  static const videoTrackHeight = 56.0;
  static const minPps = 6.0, maxPps = 400.0;

  final _scroll = ScrollController();
  double _pps = 48; // pixels per second
  bool _userScrolling = false;
  bool _programmatic = false;
  PlaybackController? _playback;

  // Pinch-zoom tracking.
  final _pointers = <int, Offset>{};
  double? _pinchStartDistance;
  double _pinchStartPps = 48;

  // Long-press clip reordering.
  String? _reorderClipId;
  double _reorderDx = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final playback = EditorScope.playbackOf(context);
    if (!identical(playback, _playback)) {
      _playback?.position.removeListener(_followPlayhead);
      _playback = playback..position.addListener(_followPlayhead);
    }
  }

  @override
  void dispose() {
    _playback?.position.removeListener(_followPlayhead);
    _scroll.dispose();
    super.dispose();
  }

  double _x(Duration t) => t.inMicroseconds / 1e6 * _pps;
  Duration _t(double x) => Duration(microseconds: (x / _pps * 1e6).round());

  void _followPlayhead() {
    if (_userScrolling || !_scroll.hasClients) return;
    final target = _x(_playback!.position.value).clamp(0.0, _scroll.position.maxScrollExtent);
    if ((target - _scroll.offset).abs() < 0.5) return;
    _programmatic = true;
    _scroll.jumpTo(target);
    _programmatic = false;
  }

  bool _onScroll(ScrollNotification n) {
    if (n.metrics.axis != Axis.horizontal) return false;
    if (n is UserScrollNotification) {
      _userScrolling = n.direction != ScrollDirection.idle;
    } else if (n is ScrollStartNotification && n.dragDetails != null) {
      _userScrolling = true;
    } else if (n is ScrollUpdateNotification && !_programmatic && _userScrolling) {
      _playback!.seek(_t(n.metrics.pixels));
    } else if (n is ScrollEndNotification) {
      _userScrolling = false;
    }
    return false;
  }

  // ---------------------------------------------------------------- pinch

  void _pointerDown(PointerDownEvent e) {
    _pointers[e.pointer] = e.position;
    if (_pointers.length == 2) {
      final pts = _pointers.values.toList();
      _pinchStartDistance = (pts[0] - pts[1]).distance;
      _pinchStartPps = _pps;
    }
  }

  void _pointerMove(PointerMoveEvent e) {
    if (!_pointers.containsKey(e.pointer)) return;
    _pointers[e.pointer] = e.position;
    if (_pointers.length == 2 && _pinchStartDistance != null && _pinchStartDistance! > 0) {
      final pts = _pointers.values.toList();
      final ratio = (pts[0] - pts[1]).distance / _pinchStartDistance!;
      setState(() => _pps = (_pinchStartPps * ratio).clamp(minPps, maxPps));
      WidgetsBinding.instance.addPostFrameCallback((_) => _followPlayhead());
    }
  }

  void _pointerUp(PointerEvent e) {
    _pointers.remove(e.pointer);
    if (_pointers.length < 2) _pinchStartDistance = null;
  }

  void _zoom(double factor) {
    setState(() => _pps = (_pps * factor).clamp(minPps, maxPps));
    WidgetsBinding.instance.addPostFrameCallback((_) => _followPlayhead());
  }

  // ---------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(editorProvider);
    final timeline = state.timeline;
    final project = state.project;

    return LayoutBuilder(
      builder: (context, box) {
        final half = box.maxWidth / 2;
        final contentWidth = math.max(_x(timeline.duration), 1.0);

        return Stack(
          children: [
            Listener(
              onPointerDown: _pointerDown,
              onPointerMove: _pointerMove,
              onPointerUp: _pointerUp,
              onPointerCancel: _pointerUp,
              child: NotificationListener<ScrollNotification>(
                onNotification: _onScroll,
                child: SingleChildScrollView(
                  child: SingleChildScrollView(
                    controller: _scroll,
                    scrollDirection: Axis.horizontal,
                    physics: const ClampingScrollPhysics(),
                    padding: EdgeInsets.symmetric(horizontal: half),
                    child: ListenableBuilder(
                      listenable: _scroll,
                      builder: (context, _) {
                        final offset = _scroll.hasClients ? _scroll.offset : 0.0;
                        // Build a little beyond the viewport on both sides.
                        final visible = (
                          start: _t(math.max(0, offset - half * 2)),
                          end: _t(offset + half * 2),
                        );
                        return SizedBox(
                          width: contentWidth + 56,
                          child: GestureDetector(
                            behavior: HitTestBehavior.translucent,
                            onTap: () =>
                                ref.read(editorProvider.notifier).select(EditorSelection.none),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                TimelineRuler(
                                  height: rulerHeight,
                                  width: contentWidth,
                                  pps: _pps,
                                  visibleStart: visible.start,
                                  visibleEnd: visible.end,
                                  onSeek: (t) => _playback!.seek(t),
                                ),
                                const SizedBox(height: 4),
                                _videoTrack(
                                  project,
                                  timeline,
                                  state.selection,
                                  visible.start,
                                  visible.end,
                                  contentWidth,
                                ),
                                const SizedBox(height: 6),
                                ..._layerLanes(
                                  project,
                                  state.selection,
                                  visible.start,
                                  visible.end,
                                  contentWidth,
                                ),
                                const SizedBox(height: 8),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ),
            ),
            // Fixed centre playhead.
            Positioned(
              left: half - 1,
              top: 0,
              bottom: 0,
              child: IgnorePointer(
                child: Container(
                  width: 2,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(1),
                    boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 3)],
                  ),
                ),
              ),
            ),
            Positioned(
              right: 6,
              top: 0,
              child: Row(
                children: [
                  _ZoomButton(icon: Icons.remove, onTap: () => _zoom(1 / 1.5)),
                  const SizedBox(width: 4),
                  _ZoomButton(icon: Icons.add, onTap: () => _zoom(1.5)),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  // ------------------------------------------------------------ video track

  Widget _videoTrack(
    Project project,
    ProjectTimeline timeline,
    EditorSelection selection,
    Duration visStart,
    Duration visEnd,
    double contentWidth,
  ) {
    final controller = ref.read(editorProvider.notifier);
    final children = <Widget>[];

    for (var i = 0; i < project.clips.length; i++) {
      final clip = project.clips[i];
      final start = timeline.clipStart(i);
      final end = timeline.clipEnd(i);
      if (end < visStart || start > visEnd) continue;
      final selected = selection.isSelected(SelectionKind.clip, clip.id);
      final isDragging = _reorderClipId == clip.id;
      children.add(
        Positioned(
          left: _x(start) + (isDragging ? _reorderDx : 0),
          top: 0,
          width: math.max(_x(clip.duration) - 2, 4),
          height: videoTrackHeight,
          child: _ClipTile(
            key: ValueKey(clip.id),
            clip: clip,
            index: i,
            pps: _pps,
            visibleStart: visStart - start,
            visibleEnd: visEnd - start,
            selected: selected,
            dragging: isDragging,
            onTap: () => controller.select(EditorSelection(SelectionKind.clip, clip.id)),
            onTrimStart: controller.beginChange,
            onTrim: (s, e) => controller.trimClip(clip.id, s, e, live: true),
            onReorderStart: () {
              HapticFeedback.mediumImpact();
              setState(() {
                _reorderClipId = clip.id;
                _reorderDx = 0;
              });
            },
            onReorderUpdate: (dx) => setState(() => _reorderDx = dx),
            onReorderEnd: () => _finishReorder(i, timeline),
          ),
        ),
      );
    }

    // Transition buttons at clip boundaries.
    for (var i = 0; i < project.clips.length - 1; i++) {
      final boundary = timeline.clipStart(i + 1) + timeline.transitionAfter(i) ~/ 2;
      if (boundary < visStart || boundary > visEnd) continue;
      final hasTransition = !project.clips[i].transition.isNone;
      children.add(
        Positioned(
          left: _x(boundary) - 12,
          top: videoTrackHeight / 2 - 12,
          width: 24,
          height: 24,
          child: GestureDetector(
            onTap: () {
              controller.select(EditorSelection(SelectionKind.clip, project.clips[i].id));
              controller.openTool(EditorTool.transition);
            },
            child: Container(
              decoration: BoxDecoration(
                color: hasTransition ? AppColors.accent : Colors.white,
                borderRadius: BorderRadius.circular(6),
                boxShadow: const [BoxShadow(color: Colors.black45, blurRadius: 3)],
              ),
              child: Icon(
                hasTransition ? Icons.auto_awesome : Icons.add,
                size: 15,
                color: hasTransition ? Colors.white : Colors.black87,
              ),
            ),
          ),
        ),
      );
    }

    // "Add clip" button after the last clip.
    children.add(
      Positioned(
        left: contentWidth + 8,
        top: 6,
        width: 44,
        height: videoTrackHeight - 12,
        child: Material(
          color: Colors.white12,
          borderRadius: BorderRadius.circular(10),
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: widget.onAddClip,
            child: const Icon(Icons.add, color: Colors.white),
          ),
        ),
      ),
    );

    return SizedBox(
      height: videoTrackHeight,
      width: contentWidth + 56,
      child: Stack(clipBehavior: Clip.none, children: children),
    );
  }

  void _finishReorder(int from, ProjectTimeline timeline) {
    final clips = timeline.clips;
    final center = _x(timeline.clipStart(from)) + _x(clips[from].duration) / 2 + _reorderDx;
    var to = from;
    for (var j = 0; j < clips.length; j++) {
      final s = _x(timeline.clipStart(j));
      final e = _x(timeline.clipEnd(j));
      if (center >= s && center < e) {
        to = j;
        break;
      }
      if (j == clips.length - 1 && center >= e) to = j;
      if (j == 0 && center < s) to = 0;
    }
    setState(() {
      _reorderClipId = null;
      _reorderDx = 0;
    });
    ref.read(editorProvider.notifier).reorderClip(from, to);
  }

  // ------------------------------------------------------------ layer lanes

  List<Widget> _layerLanes(
    Project project,
    EditorSelection selection,
    Duration visStart,
    Duration visEnd,
    double contentWidth,
  ) {
    final lanes = <Widget>[];
    void addGroup(
      SelectionKind kind,
      List<TimelineItem> items,
      Color color,
      IconData icon,
      String Function(TimelineItem) label,
    ) {
      for (final lane in assignLanes(items)) {
        lanes.add(
          TimelineLayerLane(
            kind: kind,
            items: lane,
            color: color,
            icon: icon,
            label: label,
            pps: _pps,
            width: contentWidth + 56,
            visibleStart: visStart,
            visibleEnd: visEnd,
            selection: selection,
          ),
        );
        lanes.add(const SizedBox(height: 4));
      }
    }

    addGroup(
      SelectionKind.pip,
      project.pipLayers,
      AppColors.pipTrack,
      Icons.picture_in_picture,
      (_) => 'PIP',
    );
    addGroup(
      SelectionKind.text,
      project.textLayers,
      AppColors.textTrack,
      Icons.title,
      (i) => project.textLayers.firstWhere((t) => t.id == i.id).text,
    );
    addGroup(
      SelectionKind.sticker,
      project.stickerLayers,
      AppColors.stickerTrack,
      Icons.emoji_emotions_outlined,
      (_) => 'Sticker',
    );
    addGroup(
      SelectionKind.audio,
      project.audioTracks,
      AppColors.audioTrack,
      Icons.music_note,
      (i) => project.audioTracks.firstWhere((a) => a.id == i.id).name,
    );
    return lanes;
  }
}

/// Greedy lane assignment so overlapping items don't cover each other.
List<List<TimelineItem>> assignLanes(List<TimelineItem> items) {
  final sorted = [...items]..sort((a, b) => a.start.compareTo(b.start));
  final lanes = <List<TimelineItem>>[];
  for (final item in sorted) {
    final lane = lanes.where((l) => l.last.end <= item.start).firstOrNull;
    if (lane != null) {
      lane.add(item);
    } else {
      lanes.add([item]);
    }
  }
  return lanes;
}

class _ZoomButton extends StatelessWidget {
  const _ZoomButton({required this.icon, required this.onTap});
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.black54,
    shape: const CircleBorder(),
    child: InkWell(
      customBorder: const CircleBorder(),
      onTap: onTap,
      child: Padding(padding: const EdgeInsets.all(4), child: Icon(icon, size: 16)),
    ),
  );
}

/// A main-track clip with lazily loaded thumbnails, trim handles when
/// selected, and long-press-to-reorder.
class _ClipTile extends StatefulWidget {
  const _ClipTile({
    super.key,
    required this.clip,
    required this.index,
    required this.pps,
    required this.visibleStart,
    required this.visibleEnd,
    required this.selected,
    required this.dragging,
    required this.onTap,
    required this.onTrimStart,
    required this.onTrim,
    required this.onReorderStart,
    required this.onReorderUpdate,
    required this.onReorderEnd,
  });

  final VideoClip clip;
  final int index;
  final double pps;

  /// Visible window relative to the clip start (timeline time).
  final Duration visibleStart;
  final Duration visibleEnd;
  final bool selected;
  final bool dragging;
  final VoidCallback onTap;
  final VoidCallback onTrimStart;
  final void Function(Duration start, Duration end) onTrim;
  final VoidCallback onReorderStart;
  final ValueChanged<double> onReorderUpdate;
  final VoidCallback onReorderEnd;

  @override
  State<_ClipTile> createState() => _ClipTileState();
}

class _ClipTileState extends State<_ClipTile> {
  static const handleWidth = 14.0;
  late Duration _startTrimStart, _startTrimEnd;
  double _dragDx = 0;

  void _beginTrim() {
    widget.onTrimStart();
    _startTrimStart = widget.clip.trimStart;
    _startTrimEnd = widget.clip.trimEnd;
    _dragDx = 0;
  }

  Duration _sourceDelta(double dx) =>
      Duration(microseconds: (dx / widget.pps * widget.clip.speed * 1e6).round());

  @override
  Widget build(BuildContext context) {
    final clip = widget.clip;
    return GestureDetector(
      onTap: widget.onTap,
      onLongPressStart: (_) => widget.onReorderStart(),
      onLongPressMoveUpdate: (d) => widget.onReorderUpdate(d.offsetFromOrigin.dx),
      onLongPressEnd: (_) => widget.onReorderEnd(),
      child: AnimatedScale(
        scale: widget.dragging ? 1.05 : 1,
        duration: const Duration(milliseconds: 120),
        child: Container(
          decoration: BoxDecoration(
            color: AppColors.videoTrack,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: widget.selected ? AppColors.selection : Colors.transparent,
              width: 2,
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: Stack(
            fit: StackFit.expand,
            children: [
              TimelineThumbnails(
                clip: clip,
                pps: widget.pps,
                height: _TimelineViewState.videoTrackHeight,
                visibleStart: widget.visibleStart,
                visibleEnd: widget.visibleEnd,
              ),
              Positioned(
                left: widget.selected ? handleWidth + 2 : 4,
                bottom: 2,
                child: _ClipBadges(clip: clip),
              ),
              if (widget.selected) ...[
                Positioned(
                  left: 0,
                  top: 0,
                  bottom: 0,
                  width: handleWidth,
                  child: _TrimHandle(
                    onStart: _beginTrim,
                    onUpdate: (dx) {
                      _dragDx += dx;
                      widget.onTrim(_startTrimStart + _sourceDelta(_dragDx), _startTrimEnd);
                    },
                  ),
                ),
                Positioned(
                  right: 0,
                  top: 0,
                  bottom: 0,
                  width: handleWidth,
                  child: _TrimHandle(
                    onStart: _beginTrim,
                    onUpdate: (dx) {
                      _dragDx += dx;
                      widget.onTrim(_startTrimStart, _startTrimEnd + _sourceDelta(_dragDx));
                    },
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _TrimHandle extends StatelessWidget {
  const _TrimHandle({required this.onStart, required this.onUpdate});
  final VoidCallback onStart;
  final ValueChanged<double> onUpdate;

  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onHorizontalDragStart: (_) => onStart(),
    onHorizontalDragUpdate: (d) => onUpdate(d.delta.dx),
    child: Container(
      color: AppColors.selection,
      alignment: Alignment.center,
      child: Container(width: 2, height: 18, color: Colors.black54),
    ),
  );
}

class _ClipBadges extends StatelessWidget {
  const _ClipBadges({required this.clip});
  final VideoClip clip;

  @override
  Widget build(BuildContext context) {
    final badges = <Widget>[
      if (clip.speed != 1.0) _badge('${clip.speed}x'),
      if (clip.isStill)
        _icon(Icons.photo_outlined)
      else if (clip.muted || !clip.media.hasAudio)
        _icon(Icons.volume_off),
      if (clip.hasColorChanges) _icon(Icons.auto_fix_high),
    ];
    if (badges.isEmpty) return const SizedBox.shrink();
    return Row(mainAxisSize: MainAxisSize.min, children: badges);
  }

  Widget _badge(String text) => Container(
    margin: const EdgeInsets.only(right: 3),
    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
    decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(4)),
    child: Text(text, style: const TextStyle(fontSize: 10, color: Colors.white)),
  );

  Widget _icon(IconData icon) => Container(
    margin: const EdgeInsets.only(right: 3),
    padding: const EdgeInsets.all(1.5),
    decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(4)),
    child: Icon(icon, size: 11, color: Colors.white),
  );
}
