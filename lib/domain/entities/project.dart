import 'audio_track.dart';
import 'canvas_settings.dart';
import 'export_settings.dart';
import 'pip_layer.dart';
import 'sticker_layer.dart';
import 'text_layer.dart';
import 'video_clip.dart';

/// A complete, serialisable edit. Contains only references to media files
/// (relative paths) plus editing metadata - never media bytes.
///
/// Immutable: every edit produces a new instance, which makes undo/redo a
/// matter of keeping previous instances around.
class Project {
  const Project({
    required this.id,
    required this.name,
    required this.createdAt,
    required this.updatedAt,
    this.clips = const [],
    this.audioTracks = const [],
    this.textLayers = const [],
    this.stickerLayers = const [],
    this.pipLayers = const [],
    this.canvas = const CanvasSettings(),
    this.exportSettings = const ExportSettings(),
    this.coverPath,
  });

  final String id;
  final String name;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// Main track, played in order.
  final List<VideoClip> clips;
  final List<AudioTrack> audioTracks;
  final List<TextLayer> textLayers;
  final List<StickerLayer> stickerLayers;
  final List<PipLayer> pipLayers;

  final CanvasSettings canvas;
  final ExportSettings exportSettings;

  /// Cover thumbnail, relative to the app data directory.
  final String? coverPath;

  bool get isEmpty => clips.isEmpty;

  /// Every media file this project depends on (relative paths).
  Set<String> get referencedMedia => {
    ...clips.map((c) => c.sourcePath),
    ...audioTracks.map((a) => a.sourcePath),
    ...pipLayers.map((p) => p.sourcePath),
  };

  Project copyWith({
    String? id,
    String? name,
    DateTime? createdAt,
    DateTime? updatedAt,
    List<VideoClip>? clips,
    List<AudioTrack>? audioTracks,
    List<TextLayer>? textLayers,
    List<StickerLayer>? stickerLayers,
    List<PipLayer>? pipLayers,
    CanvasSettings? canvas,
    ExportSettings? exportSettings,
    String? coverPath,
  }) => Project(
    id: id ?? this.id,
    name: name ?? this.name,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    clips: clips ?? this.clips,
    audioTracks: audioTracks ?? this.audioTracks,
    textLayers: textLayers ?? this.textLayers,
    stickerLayers: stickerLayers ?? this.stickerLayers,
    pipLayers: pipLayers ?? this.pipLayers,
    canvas: canvas ?? this.canvas,
    exportSettings: exportSettings ?? this.exportSettings,
    coverPath: coverPath ?? this.coverPath,
  );
}
