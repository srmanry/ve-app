import 'package:flutter_test/flutter_test.dart';
import 'package:video_editor_app/domain/entities/color_adjustments.dart';
import 'package:video_editor_app/domain/entities/export_settings.dart';
import 'package:video_editor_app/domain/entities/media_info.dart';
import 'package:video_editor_app/domain/entities/transition.dart';
import 'package:video_editor_app/domain/entities/video_clip.dart';
import 'package:video_editor_app/services/ffmpeg/ffmpeg_command_builder.dart';
import 'package:video_editor_app/services/video/color_matrix.dart';
import 'package:video_editor_app/services/video/video_processing_service.dart';

import '../helpers/fixtures.dart';

void main() {
  const builder = FfmpegCommandBuilder();

  List<String> render(List<VideoClip> clips) => builder.buildRender(RenderRequest(
        project: project(clips).copyWith(
            exportSettings: const ExportSettings(resolution: ExportResolution.p720)),
        settings: const ExportSettings(resolution: ExportResolution.p720),
        resolveMedia: (p) => '/abs/$p',
        outputPath: '/out/video.mp4',
      ));

  String graphOf(List<String> args) => args[args.indexOf('-filter_complex') + 1];

  test('uses input seeking and never a shell string', () {
    final c = clip('a').copyWith(trimStart: const Duration(seconds: 2), trimEnd: const Duration(seconds: 5));
    final args = render([c]);
    final i = args.indexOf('-i');
    expect(args.sublist(i - 4, i + 2), ['-ss', '2.000', '-t', '3.000', '-i', '/abs/media/a.mp4']);
    expect(args.last, '/out/video.mp4');
    expect(args, containsAllInOrder(['-c:v', 'libx264', '-c:a', 'aac', '-movflags', '+faststart']));
  });

  test('paths with spaces stay single arguments', () {
    final args = builder.buildRender(RenderRequest(
      project: project([clip('a')]),
      settings: const ExportSettings(),
      resolveMedia: (p) => '/My Videos/it\'s here.mp4',
      outputPath: '/out/my video.mp4',
    ));
    expect(args, contains('/My Videos/it\'s here.mp4'));
    expect(args.last, '/out/my video.mp4');
  });

  test('hard cuts use a single concat', () {
    final g = graphOf(render([clip('a'), clip('b'), clip('c')]));
    expect(g, contains('[v0][a0][v1][a1][v2][a2]concat=n=3:v=1:a=1'));
    expect(g, isNot(contains('xfade')));
  });

  test('transitions chain xfade with cumulative offsets', () {
    final g = graphOf(render([
      clip('a', seconds: 5, transition: TransitionType.fade),
      clip('b', seconds: 5, transition: TransitionType.crossDissolve),
      clip('c', seconds: 5),
    ]));
    expect(g, contains('xfade=transition=fade:duration=1.000:offset=4.000'));
    expect(g, contains('xfade=transition=dissolve:duration=1.000:offset=8.000'));
    expect(g, contains('acrossfade=d=1.000'));
  });

  test('speed changes video timestamps and chains atempo', () {
    final g = graphOf(render([clip('a', speed: 0.25), clip('b', speed: 4)]));
    expect(g, contains('setpts=(PTS-STARTPTS)/0.25'));
    expect(g, contains('atempo=0.5,atempo=0.5'));
    expect(g, contains('atempo=2,atempo=2,'));
  });

  test('muted or silent clips get generated silence of the right length', () {
    final g = graphOf(render([clip('a', seconds: 3).copyWith(muted: true)]));
    expect(g, contains('anullsrc=channel_layout=stereo:sample_rate=48000,atrim=duration=3.000'));
  });

  test('geometry and colour filters are emitted in preview order', () {
    final c = clip('a').copyWith(
      crop: const CropRect(0.1, 0.2, 0.5, 0.5),
      quarterTurns: 1,
      flipVertical: true,
      filter: FilterPreset.grayscale,
    );
    final g = graphOf(render([c]));
    final crop = g.indexOf('crop=w=iw*0.5');
    final rotate = g.indexOf('transpose=clock');
    final flip = g.indexOf('vflip');
    final color = g.indexOf('colorchannelmixer');
    expect([crop, rotate, flip, color].every((i) => i >= 0), isTrue);
    expect(crop < rotate && rotate < flip && flip < color, isTrue);
  });

  test('neutral clips skip the colour stage', () {
    expect(graphOf(render([clip('a')])), isNot(contains('colorchannelmixer')));
  });

  test('colour matrix offsets ride on the alpha coefficient', () {
    final m = ColorMatrix.build(FilterPreset.original, 1, const ColorAdjustments(brightness: 1));
    // +0.25 * 255 offset -> ra = 0.25
    expect(m[4], closeTo(63.75, 1e-9));
    final c = clip('a').copyWith(adjustments: const ColorAdjustments(brightness: 1));
    expect(graphOf(render([c])), contains('ra=0.25'));
  });

  test('audio extraction maps only the first audio stream', () {
    final args = builder.buildExtractAudio(const AudioExtractRequest(
      input: '/in.mp4', output: '/out.wav', format: AudioOutputFormat.wav,
    ));
    expect(args, containsAllInOrder(['-vn', '-map', '0:a:0', '-c:a', 'pcm_s16le']));
  });

  test('photos loop a still frame for exactly the clip length, with silence', () {
    final photo = VideoClip.fromMedia(
      id: 'p',
      sourcePath: 'media/p.jpg',
      media: MediaInfo.stillImage(width: 1200, height: 1600),
      stillDuration: const Duration(milliseconds: 2500),
    );
    final args = render([photo, clip('b', seconds: 4)]);
    final i = args.indexOf('/abs/media/p.jpg');
    expect(args.sublist(i - 7, i + 1),
        ['-loop', '1', '-framerate', '30', '-t', '2.500', '-i', '/abs/media/p.jpg']);
    expect(args.sublist(0, i), isNot(contains('-ss')));
    expect(graphOf(args), contains('anullsrc=channel_layout=stereo:sample_rate=48000,atrim=duration=2.500'));
  });
}
