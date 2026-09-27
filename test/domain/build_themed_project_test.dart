import 'package:flutter_test/flutter_test.dart';
import 'package:video_editor_app/domain/entities/canvas_settings.dart';
import 'package:video_editor_app/domain/entities/export_settings.dart';
import 'package:video_editor_app/domain/entities/media_info.dart';
import 'package:video_editor_app/domain/entities/project_timeline.dart';
import 'package:video_editor_app/domain/entities/video_theme.dart';
import 'package:video_editor_app/domain/repositories/media_repository.dart';
import 'package:video_editor_app/domain/usecases/build_themed_project.dart';

import '../helpers/fixtures.dart';

ImportedMedia photo(String n) => ImportedMedia(
  relativePath: 'media/$n.jpg',
  displayName: '$n.jpg',
  info: MediaInfo.stillImage(width: 1200, height: 1600),
);

ImportedMedia video(String n, int seconds) =>
    ImportedMedia(relativePath: 'media/$n.mp4', displayName: '$n.mp4', info: videoInfo(seconds: seconds));

ImportedMedia song(int seconds) => ImportedMedia(
  relativePath: 'media/song.m4a',
  displayName: 'My song.m4a',
  info: MediaInfo(duration: Duration(seconds: seconds), hasVideo: false, hasAudio: true),
);

void main() {
  const build = BuildThemedProject();
  const canvas = CanvasSettings(aspectRatio: AspectRatioPreset.portrait9x16, fit: CanvasFit.fill);

  test('photos get the theme look, pacing and transitions', () {
    final p = build(
      media: [photo('a'), photo('b'), photo('c')],
      theme: VideoTheme.vintage,
      canvas: canvas,
      exportSettings: const ExportSettings(),
    );
    expect(p.clips, hasLength(3));
    for (final c in p.clips) {
      expect(c.filter, VideoTheme.vintage.filter);
      expect(c.effect, VideoTheme.vintage.effect);
      expect(c.duration, VideoTheme.vintage.photoDuration);
      expect(c.transition.type, VideoTheme.vintage.transition);
    }
    // 3 × 3.5 s − 2 × 1 s dissolves = 8.5 s
    expect(ProjectTimeline(p).duration, const Duration(milliseconds: 8500));
    expect(p.canvas.aspectRatio, AspectRatioPreset.portrait9x16);
    expect(p.name, 'Vintage video');
  });

  test('title at the start and ending text at the end, in the theme font', () {
    final p = build(
      media: [photo('a'), photo('b')],
      theme: VideoTheme.romantic,
      canvas: canvas,
      exportSettings: const ExportSettings(),
      title: '  Our day  ',
      ending: 'The end',
    );
    final length = ProjectTimeline(p).duration;
    final title = p.textLayers.firstWhere((t) => t.text == 'Our day');
    final ending = p.textLayers.firstWhere((t) => t.text == 'The end');
    expect(title.start, Duration.zero);
    expect(title.style.fontFamily, VideoTheme.romantic.titleFont);
    expect(ending.start + ending.duration, length);
    expect(p.name, 'Our day');
  });

  test('fit to music stretches photos so the video ends with the song', () {
    final p = build(
      media: [photo('a'), video('v', 6), photo('b')],
      theme: VideoTheme.classic,
      canvas: canvas,
      exportSettings: const ExportSettings(),
      music: song(20),
      fitPhotosToMusic: true,
    );
    expect(ProjectTimeline(p).duration.inMilliseconds, closeTo(20000, 5));
    final track = p.audioTracks.single;
    expect(track.name, 'My song');
    expect(track.duration.inMilliseconds, closeTo(20000, 5));
  });

  test('music longer than the video is cut to fit; video sound can be lowered', () {
    final p = build(
      media: [video('v', 8)],
      theme: VideoTheme.cinematic,
      canvas: canvas,
      exportSettings: const ExportSettings(),
      music: song(60),
      originalSoundVolume: 0.3,
    );
    expect(p.audioTracks.single.duration, const Duration(seconds: 8));
    expect(p.clips.single.volume, 0.3);
    expect(p.clips.single.muted, isFalse);

    final silent = build(
      media: [video('v', 8)],
      theme: VideoTheme.cinematic,
      canvas: canvas,
      exportSettings: const ExportSettings(),
      originalSoundVolume: 0,
    );
    expect(silent.clips.single.muted, isTrue);
  });
}
