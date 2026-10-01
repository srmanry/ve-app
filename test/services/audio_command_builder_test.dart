import 'package:flutter_test/flutter_test.dart';
import 'package:video_editor_app/domain/entities/audio_edit.dart';
import 'package:video_editor_app/services/ffmpeg/audio_command_builder.dart';
import 'package:video_editor_app/services/video/video_processing_service.dart';

void main() {
  const builder = AudioCommandBuilder();
  const song = AudioSource('/a.mp3', Duration(seconds: 60));

  test('keep selection trims and fades on the output timeline', () {
    const job = AudioJob.single(
      source: song,
      selectionStart: Duration(seconds: 10),
      selectionEnd: Duration(seconds: 40),
      fadeOut: Duration(seconds: 2),
      format: AudioOutputFormat.mp3,
    );
    expect(job.outputDuration, const Duration(seconds: 30));
    final g = builder.graph(job);
    expect(g, contains('atrim=start=10.000:end=40.000'));
    expect(g, contains('afade=t=out:st=28.000:d=2.000'));
    expect(builder.build(job, '/o.mp3'), containsAllInOrder(['-c:a', 'libmp3lame', '-b:a', '192k']));
  });

  test('remove selection splits and concatenates', () {
    const job = AudioJob.single(
      source: song,
      selectionStart: Duration(seconds: 10),
      selectionEnd: Duration(seconds: 20),
      removeSelection: true,
      format: AudioOutputFormat.wav,
    );
    expect(job.outputDuration, const Duration(seconds: 50));
    final g = builder.graph(job);
    expect(g, contains('asplit=2'));
    expect(g, contains('concat=n=2:v=0:a=1'));
    expect(builder.build(job, '/o.wav'), isNot(contains('-b:a')));
  });

  test('speed changes output length and chains atempo', () {
    const job = AudioJob.single(source: song, speed: 2, format: AudioOutputFormat.m4a);
    expect(job.outputDuration, const Duration(seconds: 30));
    expect(builder.graph(job), contains('atempo=2'));
  });

  test('merge cross-fade is capped at half the shortest file', () {
    const job = AudioJob.merge(
      sources: [song, AudioSource('/b.wav', Duration(seconds: 4))],
      crossfade: Duration(seconds: 5),
      format: AudioOutputFormat.mp3,
    );
    expect(job.effectiveCrossfade, const Duration(seconds: 2));
    expect(job.outputDuration, const Duration(seconds: 62));
    expect(builder.graph(job), contains('acrossfade=d=2.000'));
  });

  test('mix loops only non-main tracks and limits the sum', () {
    const job = AudioJob.mix(
      tracks: [
        MixTrack(path: '/v.wav', name: 'v', sourceDuration: Duration(seconds: 30)),
        MixTrack(path: '/m.mp3', name: 'm', sourceDuration: Duration(seconds: 5), volume: 0.3,
            start: Duration(seconds: 2)),
      ],
      loopShorter: true,
      format: AudioOutputFormat.mp3,
    );
    final args = builder.build(job, '/o.mp3');
    expect(args.indexOf('-stream_loop'), greaterThan(args.indexOf('/v.wav')));
    expect(args.where((a) => a == '-stream_loop'), hasLength(1));
    final g = builder.graph(job);
    expect(g, contains('adelay=2000:all=1'));
    expect(g, contains('normalize=0'));
    expect(g, contains('alimiter'));
    expect(job.outputDuration, const Duration(seconds: 30));
  });

  test('envelope expression matches levelAt', () {
    final expr = AudioCommandBuilder.envelopeExpression(
      VolumeEnvelope.fadeIn,
      const Duration(seconds: 10),
      1,
    );
    expect(expr, startsWith('gte(t,0)*lt(t,1.5)*'));
    expect(VolumeEnvelope.fadeIn.levelAt(0), 0);
    expect(VolumeEnvelope.fadeIn.levelAt(0.075), closeTo(0.5, 1e-9));
    expect(VolumeEnvelope.fadeIn.levelAt(1), 1);
  });

  test('remove vocals cancels the centre', () {
    expect(
      AudioCommandBuilder.cleanupFilters(const CleanupSettings(CleanupMode.removeVocals)),
      ['pan=stereo|c0=c0-c1|c1=c1-c0'],
    );
  });
}
