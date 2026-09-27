import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/painting.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../../app/providers.dart';
import '../../../core/constants/app_constants.dart';
import '../../../core/errors/app_exception.dart';
import '../../../core/utils/id_generator.dart';
import '../../../domain/entities/audio_track.dart';
import '../../../domain/entities/canvas_settings.dart';
import '../../../domain/entities/color_adjustments.dart';
import '../../../domain/entities/export_settings.dart';
import '../../../domain/entities/logo_placement.dart';
import '../../../domain/entities/pip_layer.dart';
import '../../../domain/entities/project.dart';
import '../../../domain/entities/project_timeline.dart';
import '../../../domain/entities/sticker_layer.dart';
import '../../../domain/entities/text_layer.dart';
import '../../../domain/entities/transition.dart';
import '../../../domain/entities/video_clip.dart';
import '../../../domain/entities/video_effect.dart';
import '../../../domain/repositories/media_repository.dart';
import '../../../services/video/video_processing_service.dart';
import 'editor_state.dart';

/// Scoped per editor screen via `ProviderScope(overrides: [...])`.
final editorProvider = NotifierProvider.autoDispose<EditorController, EditorState>(
  () => throw UnimplementedError('editorProvider must be overridden per editor screen'),
  dependencies: const [],
);

/// All editing operations. Widgets call these methods; they never mutate
/// the project themselves.
///
/// ### Undo/redo
/// The project is immutable, so history is a stack of previous [Project]
/// snapshots (structurally shared, so cheap). Discrete actions call
/// [_commit], which records history. Continuous gestures (slider drags,
/// timeline handle drags, pinch on the preview) call [beginChange] once at
/// the start and then [updateLive] for every frame, so one gesture = one
/// undo step.
class EditorController extends Notifier<EditorState> {
  EditorController(this._initial);

  final Project _initial;

  @override
  EditorState build() => EditorState(project: _initial);

  Project get project => state.project;

  // ---------------------------------------------------------------- history

  void _commit(Project Function(Project p) change, {EditorSelection? select}) {
    final next = change(state.project);
    if (identical(next, state.project)) return;
    state = state.copyWith(
      project: next,
      undoStack: _pushBounded(state.undoStack, state.project),
      redoStack: const [],
      isDirty: true,
      selection: select,
    );
  }

  List<Project> _pushBounded(List<Project> stack, Project p) {
    final next = [...stack, p];
    return next.length > AppConstants.maxUndoSteps
        ? next.sublist(next.length - AppConstants.maxUndoSteps)
        : next;
  }

  /// Records a history checkpoint before a continuous gesture.
  void beginChange() {
    state = state.copyWith(
      undoStack: _pushBounded(state.undoStack, state.project),
      redoStack: const [],
    );
  }

  /// Applies a change without adding a history entry (see [beginChange]).
  void updateLive(Project Function(Project p) change) {
    state = state.copyWith(project: change(state.project), isDirty: true);
  }

  void undo() {
    if (!state.canUndo) return;
    final previous = state.undoStack.last;
    state = state.copyWith(
      project: previous,
      undoStack: state.undoStack.sublist(0, state.undoStack.length - 1),
      redoStack: [...state.redoStack, state.project],
      isDirty: true,
      selection: _validSelection(previous, state.selection),
    );
  }

  void redo() {
    if (!state.canRedo) return;
    final next = state.redoStack.last;
    state = state.copyWith(
      project: next,
      redoStack: state.redoStack.sublist(0, state.redoStack.length - 1),
      undoStack: [...state.undoStack, state.project],
      isDirty: true,
      selection: _validSelection(next, state.selection),
    );
  }

  EditorSelection _validSelection(Project p, EditorSelection s) {
    final exists = switch (s.kind) {
      SelectionKind.none => true,
      SelectionKind.clip => p.clips.any((c) => c.id == s.id),
      SelectionKind.audio => p.audioTracks.any((a) => a.id == s.id),
      SelectionKind.text => p.textLayers.any((t) => t.id == s.id),
      SelectionKind.sticker => p.stickerLayers.any((t) => t.id == s.id),
      SelectionKind.pip => p.pipLayers.any((t) => t.id == s.id),
    };
    return exists ? s : EditorSelection.none;
  }

  // ------------------------------------------------------------ UI state

  void select(EditorSelection selection) {
    if (selection == state.selection) return;
    var tool = state.activeTool;
    // Close clip-only panels when the selection moves off the main track.
    if (tool != null && tool.needsClip && selection.kind != SelectionKind.clip) tool = null;
    state = state.copyWith(selection: selection, activeTool: tool);
  }

  void openTool(EditorTool? tool) {
    var selection = state.selection;
    if (tool != null && tool.needsClip && state.selectedClip == null && project.clips.isNotEmpty) {
      selection = EditorSelection(SelectionKind.clip, project.clips.first.id);
    }
    state = state.copyWith(activeTool: tool, selection: selection);
  }

  // ------------------------------------------------------------ persistence

  Future<void> save() async {
    final paths = ref.read(appPathsProvider);
    var updated = project.copyWith(updatedAt: DateTime.now());
    if (updated.clips.isNotEmpty) {
      final first = updated.clips.first;
      final cover = p.join(paths.projectsDir.path, '${updated.id}.jpg');
      final ok = await ref
          .read(thumbnailServiceProvider)
          .cover(
            ref.read(mediaRepositoryProvider).resolve(first.sourcePath),
            first.isStill ? Duration.zero : first.trimStart,
            cover,
          );
      if (ok) {
        // The cover file is overwritten in place; Flutter's image cache is
        // keyed by path, so evict the stale decoded image.
        await FileImage(File(cover)).evict();
        updated = updated.copyWith(coverPath: paths.toRelative(cover));
      }
    }
    await ref.read(projectRepositoryProvider).save(updated);
    if (!ref.mounted) return;
    state = state.copyWith(project: updated, isDirty: false);
    await ref.read(projectsProvider.notifier).refresh();
  }

  void rename(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty || trimmed == project.name) return;
    _commit((p) => p.copyWith(name: trimmed));
  }

  // ------------------------------------------------------------ main track

  VideoClip _clipFromMedia(ImportedMedia m) =>
      VideoClip.fromMedia(id: newId(), sourcePath: m.relativePath, media: m.info);

  /// Inserts clips after the selected clip (or at the end).
  ///
  /// With [logo] (from the camera), a logo layer covers the added clips.
  void addClips(
    List<ImportedMedia> media, {
    List<VideoClip> recorded = const [],
    CameraLogo? logo,
  }) {
    final clips = [...media.map(_clipFromMedia), ...recorded];
    if (clips.isEmpty) return;
    final index = (state.selectedClipIndex ?? project.clips.length - 1) + 1;
    _commit((p) {
      var next = p.copyWith(clips: [...p.clips]..insertAll(index, clips));
      if (logo != null) {
        final t = ProjectTimeline(next);
        final start = t.clipStart(index);
        next = next.copyWith(
          stickerLayers: [
            ...next.stickerLayers,
            LogoPlacement.layer(
              id: newId(),
              logoPath: logo.path,
              start: start,
              duration: t.clipEnd(index + clips.length - 1) - start,
              canvasAspect: t.canvasAspectRatio,
              position: logo.position,
              scale: logo.scale,
              opacity: logo.opacity,
            ),
          ],
        );
      }
      return next;
    }, select: EditorSelection(SelectionKind.clip, clips.first.id));
  }

  void _updateClip(String id, VideoClip Function(VideoClip c) change, {bool live = false}) {
    Project apply(Project p) =>
        p.copyWith(clips: [for (final c in p.clips) c.id == id ? change(c) : c]);
    live ? updateLive(apply) : _commit(apply);
  }

  void _updateAllClips(VideoClip Function(VideoClip c) change) =>
      _commit((p) => p.copyWith(clips: p.clips.map(change).toList()));

  /// Sets the used source range of a clip, clamped to valid bounds.
  void trimClip(String id, Duration start, Duration end, {bool live = false}) {
    _updateClip(id, (c) {
      final max = c.media.duration;
      final minLen = AppConstants.minClipDuration;
      var s = _clampDur(start, Duration.zero, max - minLen);
      var e = _clampDur(end, s + minLen, max);
      if (e - s < minLen) {
        s = e - minLen;
        e = s + minLen;
      }
      return c.copyWith(trimStart: s, trimEnd: e);
    }, live: live);
  }

  /// Splits the clip under [at] (timeline time). Returns an error message
  /// when the playhead is too close to a clip edge.
  String? splitAt(Duration at) {
    final pos = state.timeline.locate(at);
    if (pos == null) return 'Add a clip first.';
    final clip = pos.clip;
    final minLen = AppConstants.minClipDuration;
    if (pos.local < minLen || clip.duration - pos.local < minLen) {
      return 'Move the playhead inside a clip to split it.';
    }
    final splitSource = pos.sourcePosition;
    final first = clip.copyWith(trimEnd: splitSource, transition: ClipTransition.none);
    final second = clip.copyWith(id: newId(), trimStart: splitSource);
    _commit(
      (p) => p.copyWith(
        clips: [...p.clips]
          ..removeAt(pos.index)
          ..insertAll(pos.index, [first, second]),
      ),
      select: EditorSelection(SelectionKind.clip, second.id),
    );
    return null;
  }

  void deleteClip(String id) {
    final index = project.clips.indexWhere((c) => c.id == id);
    if (index < 0) return;
    final remaining = [...project.clips]..removeAt(index);
    final nextSelection = remaining.isEmpty
        ? EditorSelection.none
        : EditorSelection(SelectionKind.clip, remaining[math.min(index, remaining.length - 1)].id);
    _commit((p) => p.copyWith(clips: remaining), select: nextSelection);
  }

  void duplicateClip(String id) {
    final index = project.clips.indexWhere((c) => c.id == id);
    if (index < 0) return;
    final copy = project.clips[index].copyWith(id: newId());
    _commit(
      (p) => p.copyWith(clips: [...p.clips]..insert(index + 1, copy)),
      select: EditorSelection(SelectionKind.clip, copy.id),
    );
  }

  void reorderClip(int oldIndex, int newIndex) {
    if (oldIndex == newIndex ||
        oldIndex < 0 ||
        oldIndex >= project.clips.length ||
        newIndex < 0 ||
        newIndex >= project.clips.length) {
      return;
    }
    _commit((p) {
      final clips = [...p.clips];
      final clip = clips.removeAt(oldIndex);
      clips.insert(newIndex, clip);
      return p.copyWith(clips: clips);
    });
  }

  /// Photos have no timing of their own, so speed doesn't apply to them.
  void setSpeed(String id, double speed) =>
      _updateClip(id, (c) => c.isStill ? c : c.copyWith(speed: speed));

  /// Sets how long a photo clip is shown.
  void setStillDuration(String id, Duration duration, {bool live = false}) => _updateClip(
    id,
    (c) => c.copyWith(
      trimStart: Duration.zero,
      trimEnd: _clampDur(duration, AppConstants.minClipDuration, c.media.duration),
    ),
    live: live,
  );

  /// Applies one photo duration to every photo clip (slideshow timing).
  void setAllStillDurations(Duration duration) => _updateAllClips(
    (c) => c.isStill ? c.copyWith(trimStart: Duration.zero, trimEnd: duration) : c,
  );

  void setClipVolume(String id, double volume, {bool live = false}) =>
      _updateClip(id, (c) => c.copyWith(volume: volume.clamp(0.0, 2.0)), live: live);

  void toggleClipMute(String id) => _updateClip(id, (c) => c.copyWith(muted: !c.muted));

  void setCrop(String id, CropRect crop, {bool live = false}) =>
      _updateClip(id, (c) => c.copyWith(crop: crop), live: live);

  void rotateClip(String id, {required bool clockwise}) =>
      _updateClip(id, (c) => c.copyWith(quarterTurns: (c.quarterTurns + (clockwise ? 1 : 3)) % 4));

  void flipClip(String id, {required bool horizontal}) => _updateClip(
    id,
    (c) => horizontal
        ? c.copyWith(flipHorizontal: !c.flipHorizontal)
        : c.copyWith(flipVertical: !c.flipVertical),
  );

  void setFilter(String id, FilterPreset filter, {bool applyToAll = false}) {
    VideoClip change(VideoClip c) => c.copyWith(filter: filter, filterStrength: 1.0);
    applyToAll ? _updateAllClips(change) : _updateClip(id, change);
  }

  void setFilterStrength(String id, double strength, {bool live = false}) =>
      _updateClip(id, (c) => c.copyWith(filterStrength: strength), live: live);

  void setAdjustments(String id, ColorAdjustments adjustments, {bool live = false}) =>
      _updateClip(id, (c) => c.copyWith(adjustments: adjustments), live: live);

  void setEffect(String id, VideoEffect effect, {bool applyToAll = false}) {
    VideoClip change(VideoClip c) => c.copyWith(effect: effect);
    applyToAll ? _updateAllClips(change) : _updateClip(id, change);
  }

  void setEffectIntensity(String id, double intensity, {bool live = false}) =>
      _updateClip(id, (c) => c.copyWith(effectIntensity: intensity.clamp(0.0, 1.0)), live: live);

  void setAudioDenoise(String id, DenoiseLevel level, {bool applyToAll = false}) {
    VideoClip change(VideoClip c) => c.copyWith(audioDenoise: level);
    applyToAll ? _updateAllClips(change) : _updateClip(id, change);
  }

  void setVideoDenoise(String id, DenoiseLevel level, {bool applyToAll = false}) {
    VideoClip change(VideoClip c) => c.copyWith(videoDenoise: level);
    applyToAll ? _updateAllClips(change) : _updateClip(id, change);
  }

  /// Swaps a clip's source for a processed version of its used section
  /// (e.g. after background removal). Edits like crop, filters and speed
  /// are kept.
  void replaceClipSource(String id, ImportedMedia media) => _updateClip(
    id,
    (c) => c.copyWith(
      sourcePath: media.relativePath,
      media: media.info,
      trimStart: Duration.zero,
      trimEnd: c.isStill ? c.sourceDuration : media.info.duration,
    ),
  );

  void copyLookToAll(String id) {
    final source = project.clips.where((c) => c.id == id).firstOrNull;
    if (source == null) return;
    _updateAllClips(
      (c) => c.copyWith(
        filter: source.filter,
        filterStrength: source.filterStrength,
        adjustments: source.adjustments,
      ),
    );
  }

  /// Sets the transition after clip [index].
  void setTransition(int index, ClipTransition transition, {bool applyToAll = false}) {
    if (applyToAll) {
      _updateAllClips((c) => c.copyWith(transition: transition));
    } else if (index >= 0 && index < project.clips.length) {
      _updateClip(project.clips[index].id, (c) => c.copyWith(transition: transition));
    }
  }

  /// Extracts the clip's original audio into a new audio track (aligned
  /// with the clip, respecting speed) and mutes the clip.
  Future<void> detachAudio(String clipId) async {
    final clip = project.clips.where((c) => c.id == clipId).firstOrNull;
    if (clip == null) return;
    if (!clip.media.hasAudio) {
      throw const AppException(AppErrorKind.processingFailed, 'This clip has no audio.');
    }
    final index = project.clips.indexOf(clip);
    final start = state.timeline.clipStart(index);
    final paths = ref.read(appPathsProvider);
    final media = ref.read(mediaRepositoryProvider);
    final dir = await paths.createJobDir('detach');
    state = state.copyWith(busyMessage: 'Extracting audio…');
    try {
      final out = p.join(dir.path, 'audio.m4a');
      final task = ref
          .read(videoProcessingProvider)
          .extractAudio(
            AudioExtractRequest(
              input: media.resolve(clip.sourcePath),
              output: out,
              format: AudioOutputFormat.m4a,
              start: clip.trimStart,
              duration: clip.sourceDuration,
              speed: clip.speed,
              volume: clip.volume,
              // Detached audio keeps the clip's noise removal.
              denoise: clip.audioDenoise,
            ),
          );
      await task.done;
      final imported = await media.adoptGeneratedFile(out, 'Audio from clip ${index + 1}');
      if (!ref.mounted) return;
      final track = AudioTrack(
        id: newId(),
        name: imported.displayName,
        sourcePath: imported.relativePath,
        media: imported.info,
        start: start,
        trimStart: Duration.zero,
        trimEnd: imported.info.duration,
      );
      _commit(
        (p) => p.copyWith(
          audioTracks: [...p.audioTracks, track],
          clips: [for (final c in p.clips) c.id == clipId ? c.copyWith(muted: true) : c],
        ),
        select: EditorSelection(SelectionKind.audio, track.id),
      );
    } finally {
      if (ref.mounted) state = state.copyWith(busyMessage: null);
      if (await dir.exists()) await dir.delete(recursive: true);
    }
  }

  // ------------------------------------------------------------ layers

  Duration _layerStart(Duration at) {
    final total = state.timeline.duration;
    if (at >= total - AppConstants.minClipDuration) return Duration.zero;
    return at;
  }

  Duration _layerDuration(Duration start, Duration wanted) {
    final remaining = state.timeline.duration - start;
    final d = remaining < wanted ? remaining : wanted;
    return d < AppConstants.minClipDuration ? AppConstants.minClipDuration : d;
  }

  void addAudio(ImportedMedia media, Duration at) {
    final start = _layerStart(at);
    final length = _layerDuration(start, media.info.duration);
    final track = AudioTrack(
      id: newId(),
      name: p.basenameWithoutExtension(media.displayName),
      sourcePath: media.relativePath,
      media: media.info,
      start: start,
      trimStart: Duration.zero,
      trimEnd: length,
    );
    _commit(
      (p) => p.copyWith(audioTracks: [...p.audioTracks, track]),
      select: EditorSelection(SelectionKind.audio, track.id),
    );
  }

  void updateAudio(String id, AudioTrack Function(AudioTrack a) change, {bool live = false}) {
    Project apply(Project p) =>
        p.copyWith(audioTracks: [for (final a in p.audioTracks) a.id == id ? change(a) : a]);
    live ? updateLive(apply) : _commit(apply);
  }

  void addText(String text, Duration at) {
    final start = _layerStart(at);
    final layer = TextLayer(
      id: newId(),
      text: text,
      start: start,
      duration: _layerDuration(start, const Duration(seconds: 3)),
    );
    _commit(
      (p) => p.copyWith(textLayers: [...p.textLayers, layer]),
      select: EditorSelection(SelectionKind.text, layer.id),
    );
  }

  void updateText(String id, TextLayer Function(TextLayer t) change, {bool live = false}) {
    Project apply(Project p) =>
        p.copyWith(textLayers: [for (final t in p.textLayers) t.id == id ? change(t) : t]);
    live ? updateLive(apply) : _commit(apply);
  }

  void addSticker(StickerSpec sticker, Duration at) {
    final start = _layerStart(at);
    final layer = StickerLayer(
      id: newId(),
      sticker: sticker,
      start: start,
      duration: _layerDuration(start, const Duration(seconds: 3)),
    );
    _commit(
      (p) => p.copyWith(stickerLayers: [...p.stickerLayers, layer]),
      select: EditorSelection(SelectionKind.sticker, layer.id),
    );
  }

  /// Adds a logo over the whole video, in the top-right corner by default.
  void addLogo(String logoPath, {LogoPosition position = LogoPosition.topRight}) {
    final layer = LogoPlacement.layer(
      id: newId(),
      logoPath: logoPath,
      duration: state.timeline.duration,
      canvasAspect: state.timeline.canvasAspectRatio,
      position: position,
    );
    _commit(
      (p) => p.copyWith(stickerLayers: [...p.stickerLayers, layer]),
      select: EditorSelection(SelectionKind.sticker, layer.id),
    );
  }

  /// Snaps a logo/sticker to a corner or the centre, keeping its size.
  void placeLogo(String id, LogoPosition position) => updateSticker(
    id,
    (s) => s.copyWith(
      transform: LogoPlacement.transformFor(
        position,
        s.transform.scale,
        state.timeline.canvasAspectRatio,
      ).copyWith(rotation: s.transform.rotation),
    ),
  );

  /// Makes a layer span the whole video.
  void stretchStickerToVideo(String id) =>
      updateSticker(id, (s) => s.copyWith(start: Duration.zero, duration: state.timeline.duration));

  void updateSticker(String id, StickerLayer Function(StickerLayer s) change, {bool live = false}) {
    Project apply(Project p) =>
        p.copyWith(stickerLayers: [for (final s in p.stickerLayers) s.id == id ? change(s) : s]);
    live ? updateLive(apply) : _commit(apply);
  }

  void addPip(ImportedMedia media, Duration at) {
    final start = _layerStart(at);
    final layer = PipLayer(
      id: newId(),
      sourcePath: media.relativePath,
      media: media.info,
      start: start,
      trimStart: Duration.zero,
      trimEnd: _layerDuration(start, media.info.duration),
    );
    _commit(
      (p) => p.copyWith(pipLayers: [...p.pipLayers, layer]),
      select: EditorSelection(SelectionKind.pip, layer.id),
    );
  }

  void updatePip(String id, PipLayer Function(PipLayer l) change, {bool live = false}) {
    Project apply(Project p) =>
        p.copyWith(pipLayers: [for (final l in p.pipLayers) l.id == id ? change(l) : l]);
    live ? updateLive(apply) : _commit(apply);
  }

  /// Deletes whatever is selected.
  void deleteSelection() {
    final s = state.selection;
    if (s.id == null) return;
    switch (s.kind) {
      case SelectionKind.clip:
        deleteClip(s.id!);
        return;
      case SelectionKind.audio:
        _commit(
          (p) => p.copyWith(audioTracks: p.audioTracks.where((a) => a.id != s.id).toList()),
          select: EditorSelection.none,
        );
      case SelectionKind.text:
        _commit(
          (p) => p.copyWith(textLayers: p.textLayers.where((a) => a.id != s.id).toList()),
          select: EditorSelection.none,
        );
      case SelectionKind.sticker:
        _commit(
          (p) => p.copyWith(stickerLayers: p.stickerLayers.where((a) => a.id != s.id).toList()),
          select: EditorSelection.none,
        );
      case SelectionKind.pip:
        _commit(
          (p) => p.copyWith(pipLayers: p.pipLayers.where((a) => a.id != s.id).toList()),
          select: EditorSelection.none,
        );
      case SelectionKind.none:
        return;
    }
  }

  /// Moves a secondary-track item to [start] on the timeline (live drag).
  void moveLayer(EditorSelection target, Duration start) {
    final s = start < Duration.zero ? Duration.zero : start;
    switch (target.kind) {
      case SelectionKind.audio:
        updateAudio(target.id!, (a) => a.copyWith(start: s), live: true);
      case SelectionKind.text:
        updateText(target.id!, (t) => t.copyWith(start: s), live: true);
      case SelectionKind.sticker:
        updateSticker(target.id!, (t) => t.copyWith(start: s), live: true);
      case SelectionKind.pip:
        updatePip(target.id!, (t) => t.copyWith(start: s), live: true);
      case SelectionKind.clip:
      case SelectionKind.none:
        break;
    }
  }

  /// Resizes a secondary-track item (live drag). For audio/PIP the source
  /// trim follows the edge; text/stickers just change duration.
  void resizeLayer(EditorSelection target, {Duration? newStart, Duration? newEnd}) {
    final minLen = AppConstants.minClipDuration;
    switch (target.kind) {
      case SelectionKind.text:
        updateText(target.id!, (t) {
          final (s, e) = _resizeFree(t.start, t.start + t.duration, newStart, newEnd, minLen);
          return t.copyWith(start: s, duration: e - s);
        }, live: true);
      case SelectionKind.sticker:
        updateSticker(target.id!, (t) {
          final (s, e) = _resizeFree(t.start, t.start + t.duration, newStart, newEnd, minLen);
          return t.copyWith(start: s, duration: e - s);
        }, live: true);
      case SelectionKind.audio:
        updateAudio(target.id!, (a) {
          final r = _resizeTrimmed(
            a.start,
            a.trimStart,
            a.trimEnd,
            a.media.duration,
            newStart,
            newEnd,
            minLen,
          );
          return a.copyWith(start: r.start, trimStart: r.trimStart, trimEnd: r.trimEnd);
        }, live: true);
      case SelectionKind.pip:
        updatePip(target.id!, (l) {
          final r = _resizeTrimmed(
            l.start,
            l.trimStart,
            l.trimEnd,
            l.media.duration,
            newStart,
            newEnd,
            minLen,
          );
          return l.copyWith(start: r.start, trimStart: r.trimStart, trimEnd: r.trimEnd);
        }, live: true);
      case SelectionKind.clip:
      case SelectionKind.none:
        break;
    }
  }

  (Duration, Duration) _resizeFree(
    Duration start,
    Duration end,
    Duration? newStart,
    Duration? newEnd,
    Duration minLen,
  ) {
    var s = newStart ?? start, e = newEnd ?? end;
    if (s < Duration.zero) s = Duration.zero;
    if (e - s < minLen) {
      if (newStart != null) {
        s = e - minLen;
      } else {
        e = s + minLen;
      }
    }
    return (s, e);
  }

  ({Duration start, Duration trimStart, Duration trimEnd}) _resizeTrimmed(
    Duration start,
    Duration trimStart,
    Duration trimEnd,
    Duration sourceLength,
    Duration? newStart,
    Duration? newEnd,
    Duration minLen,
  ) {
    var s = start, ts = trimStart, te = trimEnd;
    if (newStart != null) {
      // Left edge: shift both timeline start and source in-point.
      var delta = newStart - start;
      if (ts + delta < Duration.zero) delta = -ts;
      if (s + delta < Duration.zero) delta = -s;
      if (te - (ts + delta) < minLen) delta = te - minLen - ts;
      s += delta;
      ts += delta;
    }
    if (newEnd != null) {
      te = _clampDur(ts + (newEnd - s), ts + minLen, sourceLength);
    }
    return (start: s, trimStart: ts, trimEnd: te);
  }

  // ------------------------------------------------------------ project-wide

  void setCanvas(CanvasSettings canvas) => _commit((p) => p.copyWith(canvas: canvas));

  void setExportSettings(ExportSettings settings) {
    // Export preferences are not an "edit"; don't pollute undo history.
    state = state.copyWith(project: project.copyWith(exportSettings: settings), isDirty: true);
  }

  /// Checks that every referenced media file still exists.
  Future<List<String>> missingMedia() async {
    final media = ref.read(mediaRepositoryProvider);
    final missing = <String>[];
    for (final path in project.referencedMedia) {
      if (!await File(media.resolve(path)).exists()) missing.add(path);
    }
    return missing;
  }

  /// Removes items whose media is missing so the rest can still be edited.
  void removeMissingMedia(List<String> missing) {
    final set = missing.toSet();
    _commit(
      (p) => p.copyWith(
        clips: p.clips.where((c) => !set.contains(c.sourcePath)).toList(),
        audioTracks: p.audioTracks.where((a) => !set.contains(a.sourcePath)).toList(),
        pipLayers: p.pipLayers.where((l) => !set.contains(l.sourcePath)).toList(),
      ),
      select: EditorSelection.none,
    );
  }

  ProjectTimeline get timeline => state.timeline;

  static Duration _clampDur(Duration v, Duration min, Duration max) {
    if (max < min) return min;
    if (v < min) return min;
    if (v > max) return max;
    return v;
  }
}
