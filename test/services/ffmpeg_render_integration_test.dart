// Runs generated FFmpeg commands against a real ffmpeg binary.
//
//   FFMPEG_BIN=/path/to/ffmpeg FFPROBE_BIN=/path/to/ffprobe \
//   TEST_MEDIA_DIR=/path/to/media flutter test test/services
//
// TEST_MEDIA_DIR must contain: a.mp4 (1080p30 + audio), b_rot.mov
// (rotated 90°, audio), c.mkv (no audio), music.m4a, overlay.png.
// Skipped when the variables are not set (e.g. on CI without ffmpeg).
//
// Create the media with:
//   ffmpeg -f lavfi -i testsrc2=size=1920x1080:rate=30 -f lavfi -i sine -t 6 \
//     -c:v libx264 -pix_fmt yuv420p -c:a aac a.mp4
//   ffmpeg -f lavfi -i testsrc=size=1920x1080:rate=25 -f lavfi -i sine=frequency=660 -t 5 \
//     -c:v libx264 -pix_fmt yuv420p -c:a aac b_raw.mp4
//   ffmpeg -display_rotation 90 -i b_raw.mp4 -c copy b_rot.mov
//   ffmpeg -f lavfi -i mandelbrot=size=640x480:rate=24 -t 4 -c:v libx264 -pix_fmt yuv420p c.mkv
//   ffmpeg -f lavfi -i sine=frequency=220:sample_rate=48000 -t 10 -c:a aac music.m4a
//   ffmpeg -f lavfi -i "color=c=red@0.5:size=1080x1080,format=rgba" -frames:v 1 overlay.png
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_editor_app/domain/entities/audio_track.dart';
import 'package:video_editor_app/domain/entities/canvas_settings.dart';
import 'package:video_editor_app/domain/entities/color_adjustments.dart';
import 'package:video_editor_app/domain/entities/export_settings.dart';
import 'package:video_editor_app/domain/entities/layer_transform.dart';
import 'package:video_editor_app/domain/entities/media_info.dart';
import 'package:video_editor_app/domain/entities/pip_layer.dart';
import 'package:video_editor_app/domain/entities/project.dart';
import 'package:video_editor_app/domain/entities/project_timeline.dart';
import 'package:video_editor_app/domain/entities/transition.dart';
import 'package:video_editor_app/domain/entities/video_clip.dart';
import 'package:video_editor_app/domain/entities/video_effect.dart';
import 'package:video_editor_app/services/ffmpeg/ffmpeg_command_builder.dart';
import 'package:video_editor_app/services/ffmpeg/media_info_parser.dart';
import 'package:video_editor_app/services/video/video_processing_service.dart';

final _ffmpeg = Platform.environment['FFMPEG_BIN'];
final _ffprobe = Platform.environment['FFPROBE_BIN'];
final _mediaDir = Platform.environment['TEST_MEDIA_DIR'];

Future<MediaInfo> _probe(String path) async {
  final r = await Process.run(_ffprobe!, [
    '-v', 'error', '-print_format', 'json', '-show_format', '-show_streams', path,
  ]);
  final json = jsonDecode(r.stdout as String) as Map<String, dynamic>;
  return MediaInfoParser.parse(json)!;
}

Future<void> _run(List<String> args) async {
  final r = await Process.run(_ffmpeg!, args);
  if (r.exitCode != 0) {
    fail('ffmpeg failed (${r.exitCode}):\n${args.join(' ')}\n${r.stderr}');
  }
}

void main() {
  final skip = _ffmpeg == null || _ffprobe == null || _mediaDir == null
      ? 'FFMPEG_BIN / FFPROBE_BIN / TEST_MEDIA_DIR not set'
      : null;
  const builder = FfmpegCommandBuilder();
  late Directory out;

  String media(String name) => '$_mediaDir/$name';

  setUpAll(() async {
    if (skip != null) return;
    final keep = Platform.environment['RENDER_OUT'];
    out = keep != null
        ? await Directory(keep).create(recursive: true)
        : await Directory.systemTemp.createTemp('render_test');
  });

  Future<VideoClip> clip(String name, {Duration? start, Duration? end}) async {
    final info = await _probe(media(name));
    return VideoClip(
      id: name,
      sourcePath: name,
      media: info,
      trimStart: start ?? Duration.zero,
      trimEnd: end ?? info.duration,
    );
  }

  Future<MediaInfo> renderAndProbe(Project project, String outName,
      {List<OverlayImage> overlays = const []}) async {
    final output = '${out.path}/$outName';
    final args = builder.buildRender(RenderRequest(
      project: project,
      settings: project.exportSettings,
      resolveMedia: media,
      outputPath: output,
      overlays: overlays,
    ));
    await _run(args);
    return _probe(output);
  }

  Project project(List<VideoClip> clips,
          {CanvasSettings canvas = const CanvasSettings(),
          ExportSettings export = const ExportSettings(resolution: ExportResolution.p480)}) =>
      Project(
        id: 'p',
        name: 'test',
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
        clips: clips,
        canvas: canvas,
        exportSettings: export,
      );

  test('parser reads rotation, fps and audio presence', () async {
    final a = await _probe(media('a.mp4'));
    expect(a.displayWidth, 1920);
    expect(a.frameRate, closeTo(30, 0.01));
    expect(a.hasAudio, isTrue);

    final b = await _probe(media('b_rot.mov'));
    expect(b.rotation % 180, 90);
    expect(b.isPortrait, isTrue);

    final c = await _probe(media('c.mkv'));
    expect(c.hasAudio, isFalse);
  }, skip: skip);

  test('single trimmed clip at 480p', () async {
    final p = project([await clip('a.mp4', start: const Duration(seconds: 1), end: const Duration(seconds: 4))]);
    final info = await renderAndProbe(p, 'trim.mp4');
    expect(info.duration.inMilliseconds, closeTo(3000, 100));
    expect(info.displayWidth, 854);
    expect(info.displayHeight, 480);
    expect(info.hasAudio, isTrue);
  }, skip: skip);

  test('merge mixed sizes/rotation/no-audio with cuts on 9:16 canvas', () async {
    final p = project(
      [await clip('a.mp4'), await clip('b_rot.mov'), await clip('c.mkv')],
      canvas: const CanvasSettings(aspectRatio: AspectRatioPreset.portrait9x16),
    );
    final expected = ProjectTimeline(p).duration;
    final info = await renderAndProbe(p, 'merge.mp4');
    expect(info.width, 480);
    expect(info.height, 854);
    expect(info.duration.inMilliseconds, closeTo(expected.inMilliseconds, 150));
  }, skip: skip);

  test('transitions, speed, crop, rotate, flip, filters', () async {
    final a = await clip('a.mp4');
    final b = await clip('b_rot.mov');
    final c = await clip('c.mkv');
    final p = project([
      a.copyWith(
        speed: 2.0,
        crop: const CropRect(0.1, 0.1, 0.5, 0.6),
        filter: FilterPreset.vintage,
        transition: const ClipTransition(type: TransitionType.fade),
      ),
      b.copyWith(
        speed: 0.5,
        quarterTurns: 1,
        flipHorizontal: true,
        adjustments: const ColorAdjustments(brightness: 0.2, temperature: 0.5, shadows: 0.3),
        transition: const ClipTransition(type: TransitionType.slide, duration: Duration(milliseconds: 1500)),
      ),
      c.copyWith(
        speed: 0.25,
        filter: FilterPreset.grayscale,
        transition: const ClipTransition(type: TransitionType.zoom),
      ),
      a.copyWith(id: 'a2', speed: 4.0, trimEnd: const Duration(seconds: 4)),
    ], canvas: const CanvasSettings(aspectRatio: AspectRatioPreset.square1x1, fit: CanvasFit.fill));
    final expected = ProjectTimeline(p).duration;
    final info = await renderAndProbe(p, 'effects.mp4');
    expect(info.width, 480);
    expect(info.height, 480);
    expect(info.duration.inMilliseconds, closeTo(expected.inMilliseconds, 150));
  }, skip: skip);

  test('mixed hard cuts and transitions (incl. split clips of one source)', () async {
    final a = await clip('a.mp4');
    final p = project([
      a.copyWith(trimEnd: const Duration(seconds: 2)),
      a.copyWith(id: 'a2', trimStart: const Duration(seconds: 2),
          transition: const ClipTransition(type: TransitionType.crossDissolve)),
      await clip('c.mkv'),
    ]);
    final expected = ProjectTimeline(p).duration;
    final info = await renderAndProbe(p, 'mixed.mp4');
    expect(info.duration.inMilliseconds, closeTo(expected.inMilliseconds, 150));
  }, skip: skip);

  test('music, PIP and overlays are mixed/composited', () async {
    final a = await clip('a.mp4');
    final music = await _probe(media('music.m4a'));
    final pipInfo = await _probe(media('b_rot.mov'));
    final p = project([a]).copyWith(
      audioTracks: [
        AudioTrack(
          id: 'm', name: 'music', sourcePath: 'music.m4a', media: music,
          start: const Duration(seconds: 1), trimStart: const Duration(seconds: 2),
          trimEnd: const Duration(seconds: 9), volume: 0.5,
        ),
      ],
      pipLayers: [
        PipLayer(
          id: 'pip', sourcePath: 'b_rot.mov', media: pipInfo,
          start: const Duration(seconds: 2), trimStart: Duration.zero,
          trimEnd: const Duration(seconds: 3),
          transform: const LayerTransform(x: 0.7, y: 0.3, scale: 0.35, rotation: 0.3),
        ),
      ],
    );
    final info = await renderAndProbe(p, 'layers.mp4', overlays: [
      OverlayImage(path: media('overlay.png'), start: const Duration(seconds: 1), end: const Duration(seconds: 3)),
    ]);
    // Main track defines the length even though music runs past the end.
    expect(info.duration.inMilliseconds, closeTo(6000, 150));
    expect(info.hasAudio, isTrue);
  }, skip: skip);

  test('photo slideshow: stills + transitions + music on a 9:16 canvas', () async {
    // Photos as they arrive after import: upright JPEGs.
    await _run(['-y', '-f', 'lavfi', '-i', 'testsrc2=size=1600x1200', '-frames:v', '1', '${out.path}/land.jpg']);
    await _run(['-y', '-f', 'lavfi', '-i', 'smptebars=size=900x1600', '-frames:v', '1', '${out.path}/port.jpg']);
    VideoClip photo(String name, int w, int h) => VideoClip.fromMedia(
          id: name,
          sourcePath: '${out.path}/$name',
          media: MediaInfo.stillImage(width: w, height: h),
          stillDuration: const Duration(seconds: 2),
        ).copyWith(transition: const ClipTransition(type: TransitionType.fade,
            duration: Duration(milliseconds: 500)));
    final music = await _probe(media('music.m4a'));
    final p = project(
      [photo('land.jpg', 1600, 1200), photo('port.jpg', 900, 1600), photo('land.jpg', 1600, 1200)],
      canvas: const CanvasSettings(aspectRatio: AspectRatioPreset.portrait9x16, fit: CanvasFit.fill),
    ).copyWith(audioTracks: [
      AudioTrack(id: 'm', name: 'music', sourcePath: 'music.m4a', media: music,
          start: Duration.zero, trimStart: Duration.zero, trimEnd: const Duration(seconds: 5)),
    ]);
    final expected = ProjectTimeline(p).duration; // 3·2 − 2·0.5 = 5 s
    expect(expected, const Duration(seconds: 5));
    final output = '${out.path}/slideshow.mp4';
    await _run(builder.buildRender(RenderRequest(
      project: p,
      settings: p.exportSettings,
      // Photo paths are absolute here; other media come from TEST_MEDIA_DIR.
      resolveMedia: (rel) => rel.startsWith('/') ? rel : media(rel),
      outputPath: output,
    )));
    final info = await _probe(output);
    expect((info.width, info.height), (480, 854));
    expect(info.duration.inMilliseconds, closeTo(5000, 150));
    expect(info.hasAudio, isTrue);
  }, skip: skip);

  test('every effect and noise-reduction level renders', () async {
    final a = await clip('a.mp4', end: const Duration(seconds: 2));
    // All effects in one project (mirror twice to check unique labels).
    final clips = [
      for (final e in VideoEffect.values)
        a.copyWith(id: e.name, effect: e, effectIntensity: 0.8),
      a.copyWith(id: 'mirror2', effect: VideoEffect.mirror),
      for (final d in DenoiseLevel.values)
        a.copyWith(id: 'dn${d.name}', audioDenoise: d, videoDenoise: d),
    ];
    final p = project(clips);
    final info = await renderAndProbe(p, 'effects_all.mp4');
    expect(info.duration.inMilliseconds,
        closeTo(ProjectTimeline(p).duration.inMilliseconds, 200));
  }, skip: skip);

  test('background removal: frames → masks → composite (color, blur, image, photo)', () async {
    final a = await _probe(media('a.mp4'));
    Future<void> runJob(BackgroundJob job, String name) async {
      final frames = await Directory('${out.path}/$name-frames').create(recursive: true);
      await _run(builder.buildSegmentationFrames(job, '${frames.path}/%06d.jpg'));
      final count = frames.listSync().length;
      expect(count, job.isStill ? 1 : closeTo(job.fps * job.duration.inSeconds, 2));
      // Stand-in for the native model: a centred ellipse as "the person".
      final masks = '${out.path}/$name.gray';
      await _run(['-y', '-i', '${frames.path}/%06d.jpg', '-vf',
          "format=gray,geq=lum='if(lt(hypot((X-W/2)/W*2,(Y-H/2)/H*2),0.6),255,0)'",
          '-f', 'rawvideo', '-pix_fmt', 'gray', masks]);
      expect(File(masks).lengthSync(), count * job.maskWidth * job.maskHeight);
      final output = '${out.path}/$name.${job.isStill ? 'jpg' : 'mp4'}';
      await _run(builder.buildBackgroundComposite(job, masks, output));
      final info = await _probe(output);
      expect((info.width, info.height), (job.outputWidth, job.outputHeight));
      if (!job.isStill) {
        expect(info.duration.inMilliseconds, closeTo(job.duration.inMilliseconds, 150));
        expect(info.hasAudio, isTrue);
      }
    }

    BackgroundJob job(BackgroundFill fill, {bool still = false}) => BackgroundJob(
          input: still ? '${out.path}/port.jpg' : media('a.mp4'),
          isStill: still,
          start: const Duration(seconds: 1),
          duration: const Duration(seconds: 2),
          displayWidth: still ? 900 : a.displayWidth,
          displayHeight: still ? 1600 : a.displayHeight,
          fill: fill,
        );
    await _run(['-y', '-f', 'lavfi', '-i', 'smptebars=size=900x1600', '-frames:v', '1', '${out.path}/port.jpg']);
    await runJob(job(const BackgroundFill.color(0xFF00C853)), 'bg_color');
    await runJob(job(const BackgroundFill.blur()), 'bg_blur');
    await runJob(job(BackgroundFill.image(media('overlay.png'))), 'bg_image');
    await runJob(job(const BackgroundFill.color(0xFF2962FF), still: true), 'bg_still');
  }, skip: skip);

  test('extract audio (m4a with speed) and editing proxy', () async {
    await _run(builder.buildExtractAudio(AudioExtractRequest(
      input: media('a.mp4'),
      output: '${out.path}/audio.m4a',
      format: AudioOutputFormat.m4a,
      start: const Duration(seconds: 1),
      duration: const Duration(seconds: 4),
      speed: 0.5,
    )));
    final audio = await _probe('${out.path}/audio.m4a');
    expect(audio.hasVideo, isFalse);
    expect(audio.duration.inMilliseconds, closeTo(8000, 150));

    await _run(builder.buildEditingProxy(input: media('c.mkv'), output: '${out.path}/proxy.mp4'));
    final proxy = await _probe('${out.path}/proxy.mp4');
    expect(proxy.videoCodec, 'h264');

    await _run(builder.buildExtractFrame(
        input: media('a.mp4'), at: const Duration(seconds: 2), output: '${out.path}/f.jpg', maxWidth: 160));
    expect(File('${out.path}/f.jpg').existsSync(), isTrue);
  }, skip: skip);
}
