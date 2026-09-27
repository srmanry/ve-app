import 'dart:math' as math;

import '../../core/utils/id_generator.dart';
import '../entities/audio_track.dart';
import '../entities/canvas_settings.dart';
import '../entities/export_settings.dart';
import '../entities/layer_transform.dart';
import '../entities/project.dart';
import '../entities/project_timeline.dart';
import '../entities/text_layer.dart';
import '../entities/video_clip.dart';
import '../entities/video_theme.dart';
import '../repositories/media_repository.dart';

/// Builds a ready-to-edit project from the user's photos/videos, a
/// [VideoTheme], optional title/ending text and optional music.
///
/// Pure: no I/O, so it is unit-tested directly.
class BuildThemedProject {
  const BuildThemedProject();

  static const _minPhoto = Duration(milliseconds: 800);

  Project call({
    required List<ImportedMedia> media,
    required VideoTheme theme,
    required CanvasSettings canvas,
    required ExportSettings exportSettings,
    String title = '',
    String ending = '',
    ImportedMedia? music,
    bool fitPhotosToMusic = false,
    double originalSoundVolume = 1.0,
    String? name,
    DateTime? now,
  }) {
    assert(media.isNotEmpty);
    final at = now ?? DateTime.now();
    final photoLength = fitPhotosToMusic && music != null
        ? _photoLengthForMusic(media, theme, music.info.duration)
        : theme.photoDuration;

    final clips = [
      for (final m in media)
        VideoClip.fromMedia(
          id: newId(),
          sourcePath: m.relativePath,
          media: m.info,
          stillDuration: photoLength,
        ).copyWith(
          filter: theme.filter,
          filterStrength: theme.filterStrength,
          effect: theme.effect,
          effectIntensity: theme.effectIntensity,
          transition: theme.clipTransition,
          // With music, the camera's own sound is usually turned down.
          volume: originalSoundVolume.clamp(0.0, 2.0),
          muted: originalSoundVolume <= 0,
        ),
    ];

    var project = Project(
      id: newId(),
      name: name ?? (title.trim().isNotEmpty ? title.trim() : '${theme.label} video'),
      createdAt: at,
      updatedAt: at,
      clips: clips,
      canvas: canvas,
      exportSettings: exportSettings,
    );
    final length = ProjectTimeline(project).duration;

    final texts = <TextLayer>[
      if (title.trim().isNotEmpty)
        _text(theme, title.trim(), Duration.zero, _min(const Duration(seconds: 3), length), 0.5),
      if (ending.trim().isNotEmpty && length > const Duration(seconds: 1))
        () {
          final d = _min(const Duration(milliseconds: 2500), length);
          return _text(theme, ending.trim(), length - d, d, 0.82, sizeFactor: 0.7);
        }(),
    ];

    final tracks = <AudioTrack>[
      if (music != null)
        AudioTrack(
          id: newId(),
          name: music.displayName.replaceAll(RegExp(r'\.[^.]+$'), ''),
          sourcePath: music.relativePath,
          media: music.info,
          start: Duration.zero,
          trimStart: Duration.zero,
          trimEnd: _min(music.info.duration, length),
        ),
    ];

    project = project.copyWith(textLayers: texts, audioTracks: tracks);
    return project;
  }

  /// Photo length so the whole video lasts as long as the song, given that
  /// videos keep their own length and transitions overlap neighbours.
  Duration _photoLengthForMusic(List<ImportedMedia> media, VideoTheme theme, Duration song) {
    final photos = media.where((m) => m.info.isStillImage).length;
    if (photos == 0) return theme.photoDuration;
    final videos = media
        .where((m) => !m.info.isStillImage)
        .fold<Duration>(Duration.zero, (s, m) => s + m.info.duration);
    final overlaps = Duration(milliseconds: theme.transitionMs) * (media.length - 1);
    final us = (song - videos + overlaps).inMicroseconds ~/ photos;
    return Duration(microseconds: math.max(us, _minPhoto.inMicroseconds));
  }

  TextLayer _text(
    VideoTheme theme,
    String text,
    Duration start,
    Duration duration,
    double y, {
    double sizeFactor = 1,
  }) => TextLayer(
    id: newId(),
    text: text,
    start: start,
    duration: duration,
    transform: LayerTransform(y: y),
    style: TextLayerStyle(
      fontFamily: theme.titleFont,
      fontSize: theme.titleSize * sizeFactor,
      color: theme.titleColor,
      bold: false,
      shadow: true,
    ),
  );

  static Duration _min(Duration a, Duration b) => a < b ? a : b;
}
