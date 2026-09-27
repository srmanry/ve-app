import '../../../domain/entities/audio_track.dart';
import '../../../domain/entities/pip_layer.dart';
import '../../../domain/entities/project.dart';
import '../../../domain/entities/project_timeline.dart';
import '../../../domain/entities/sticker_layer.dart';
import '../../../domain/entities/text_layer.dart';
import '../../../domain/entities/video_clip.dart';

enum EditorTool {
  trim('Trim'),
  split('Split'),
  crop('Crop'),
  rotate('Rotate'),
  speed('Speed'),
  volume('Volume'),
  audio('Audio'),
  text('Text'),
  sticker('Sticker'),
  logo('Logo'),
  filter('Filter'),
  adjust('Adjust'),
  transition('Transition'),
  pip('PIP'),
  effects('Effects'),
  denoise('Denoise'),
  removeBackground('Remove BG'),
  canvas('Canvas');

  const EditorTool(this.label);
  final String label;

  /// Tools that operate on the selected main-track clip.
  bool get needsClip => switch (this) {
    trim ||
    crop ||
    rotate ||
    speed ||
    volume ||
    filter ||
    adjust ||
    transition ||
    effects ||
    denoise ||
    removeBackground => true,
    _ => false,
  };
}

enum SelectionKind { none, clip, audio, text, sticker, pip }

class EditorSelection {
  const EditorSelection(this.kind, [this.id]);
  static const none = EditorSelection(SelectionKind.none);

  final SelectionKind kind;
  final String? id;

  bool isSelected(SelectionKind k, String itemId) => kind == k && id == itemId;

  @override
  bool operator ==(Object other) =>
      other is EditorSelection && other.kind == kind && other.id == id;

  @override
  int get hashCode => Object.hash(kind, id);
}

/// Everything the editor UI renders, except the high-frequency playhead
/// position, which lives in `PlaybackController.position` so that playback
/// only rebuilds the playhead/timestamp widgets, not the whole editor.
class EditorState {
  EditorState({
    required this.project,
    this.selection = EditorSelection.none,
    this.activeTool,
    this.undoStack = const [],
    this.redoStack = const [],
    this.isDirty = false,
    this.busyMessage,
  });

  final Project project;
  final EditorSelection selection;
  final EditorTool? activeTool;
  final List<Project> undoStack;
  final List<Project> redoStack;
  final bool isDirty;

  /// Non-null while a blocking operation (import, audio extraction) runs.
  final String? busyMessage;

  late final ProjectTimeline timeline = ProjectTimeline(project);

  bool get canUndo => undoStack.isNotEmpty;
  bool get canRedo => redoStack.isNotEmpty;

  VideoClip? get selectedClip => selection.kind == SelectionKind.clip
      ? project.clips.where((c) => c.id == selection.id).firstOrNull
      : null;

  int? get selectedClipIndex {
    final clip = selectedClip;
    return clip == null ? null : project.clips.indexOf(clip);
  }

  AudioTrack? get selectedAudio => selection.kind == SelectionKind.audio
      ? project.audioTracks.where((a) => a.id == selection.id).firstOrNull
      : null;

  TextLayer? get selectedText => selection.kind == SelectionKind.text
      ? project.textLayers.where((t) => t.id == selection.id).firstOrNull
      : null;

  StickerLayer? get selectedSticker => selection.kind == SelectionKind.sticker
      ? project.stickerLayers.where((s) => s.id == selection.id).firstOrNull
      : null;

  PipLayer? get selectedPip => selection.kind == SelectionKind.pip
      ? project.pipLayers.where((p) => p.id == selection.id).firstOrNull
      : null;

  EditorState copyWith({
    Project? project,
    EditorSelection? selection,
    Object? activeTool = _keep,
    List<Project>? undoStack,
    List<Project>? redoStack,
    bool? isDirty,
    Object? busyMessage = _keep,
  }) => EditorState(
    project: project ?? this.project,
    selection: selection ?? this.selection,
    activeTool: identical(activeTool, _keep) ? this.activeTool : activeTool as EditorTool?,
    undoStack: undoStack ?? this.undoStack,
    redoStack: redoStack ?? this.redoStack,
    isDirty: isDirty ?? this.isDirty,
    busyMessage: identical(busyMessage, _keep) ? this.busyMessage : busyMessage as String?,
  );
}

const _keep = Object();
