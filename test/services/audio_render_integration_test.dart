// Runs generated audio-tool commands against a real ffmpeg binary.
//
//   FFMPEG_BIN=/path/to/ffmpeg FFPROBE_BIN=/path/to/ffprobe \
//   AUDIO_MEDIA_DIR=/path/to/media flutter test test/services
//
// AUDIO_MEDIA_DIR must contain a.mp4 (6 s, audio), music.m4a (10 s, 48 kHz),
// song.mp3 (8 s stereo, 44.1 kHz) and voice.wav (5 s mono, 22 kHz):
//   ffmpeg -f lavfi -i testsrc2=size=640x360:rate=30 -f lavfi -i sine -t 6 \
//     -c:v libx264 -pix_fmt yuv420p -c:a aac a.mp4
//   ffmpeg -f lavfi -i sine=frequency=220:sample_rate=48000 -t 10 -c:a aac music.m4a
//   ffmpeg -f lavfi -i sine=frequency=440 -f lavfi -i sine=frequency=880 \
//     -filter_complex "[0][1]amerge=inputs=2" -t 8 -c:a libmp3lame song.mp3
//   ffmpeg -f lavfi -i "anoisesrc=d=5:c=pink:a=0.1" -ac 1 -ar 22050 voice.wav
// Skipped when the variables are not set.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_editor_app/domain/entities/audio_edit.dart';
import 'package:video_editor_app/services/audio/waveform_service.dart';
import 'package:video_editor_app/services/ffmpeg/audio_command_builder.dart';
import 'package:video_editor_app/services/video/video_processing_service.dart';

final _ffmpeg = Platform.environment['FFMPEG_BIN'];
final _ffprobe = Platform.environment['FFPROBE_BIN'];
final _mediaDir = Platform.environment['AUDIO_MEDIA_DIR'];

class _Probe {
  _Probe(this.duration, this.codec, this.channels, this.bitRate);
  final Duration duration;
  final String codec;
  final int channels;
  final int? bitRate;
}

Future<_Probe> _probe(String path) async {
  final r = await Process.run(_ffprobe!, [
    '-v', 'error', '-print_format', 'json', '-show_format', '-show_streams', path,
  ]);
  final json = jsonDecode(r.stdout as String) as Map<String, dynamic>;
  final stream = (json['streams'] as List).cast<Map<String, dynamic>>().firstWhere(
    (s) => s['codec_type'] == 'audio',
  );
  final format = json['format'] as Map<String, dynamic>;
  final seconds = double.parse(format['duration'] as String);
  return _Probe(
    Duration(microseconds: (seconds * 1e6).round()),
    stream['codec_name'] as String,
    stream['channels'] as int,
    int.tryParse('${format['bit_rate']}'),
  );
}

void main() {
  final skip = _ffmpeg == null || _ffprobe == null || _mediaDir == null
      ? 'FFMPEG_BIN / FFPROBE_BIN / AUDIO_MEDIA_DIR not set'
      : null;
  const builder = AudioCommandBuilder();
  late Directory out;

  String media(String name) => '$_mediaDir/$name';

  setUpAll(() async {
    if (skip != null) return;
    out = await Directory.systemTemp.createTemp('audio_test');
  });

  Future<AudioSource> source(String name) async =>
      AudioSource(media(name), (await _probe(media(name))).duration);

  Future<_Probe> render(AudioJob job, String name) async {
    final path = '${out.path}/$name';
    final args = builder.build(job, path);
    final r = await Process.run(_ffmpeg!, args);
    if (r.exitCode != 0) {
      fail('ffmpeg failed (${r.exitCode}):\n${args.join(' ')}\n${r.stderr}');
    }
    final probe = await _probe(path);
    // Output length must match what the progress bar expects.
    expect(
      (probe.duration - job.outputDuration).inMilliseconds.abs(),
      lessThan(150),
      reason: 'duration ${probe.duration} vs expected ${job.outputDuration}',
    );
    return probe;
  }

  group('audio tools (real ffmpeg)', skip: skip, () {
    test('cut keeps a selection with fades, as MP3', () async {
      final p = await render(
        AudioJob.single(
          source: await source('song.mp3'),
          selectionStart: const Duration(seconds: 2),
          selectionEnd: const Duration(milliseconds: 5500),
          fadeIn: const Duration(milliseconds: 500),
          fadeOut: const Duration(seconds: 1),
          format: AudioOutputFormat.mp3,
        ),
        'cut.mp3',
      );
      expect(p.codec, 'mp3');
    });

    test('cut removes the middle of a song', () async {
      await render(
        AudioJob.single(
          source: await source('song.mp3'),
          selectionStart: const Duration(seconds: 2),
          selectionEnd: const Duration(seconds: 5),
          removeSelection: true,
          format: AudioOutputFormat.m4a,
        ),
        'remove_mid.m4a',
      );
    });

    test('cut removes the start only', () async {
      await render(
        AudioJob.single(
          source: await source('song.mp3'),
          selectionEnd: const Duration(seconds: 3),
          removeSelection: true,
          format: AudioOutputFormat.wav,
        ),
        'remove_head.wav',
      );
    });

    test('video to audio with speed, volume, loudness', () async {
      final p = await render(
        AudioJob.single(
          source: await source('a.mp4'),
          speed: 1.5,
          volume: 1.4,
          normalize: true,
          format: AudioOutputFormat.mp3,
          quality: AudioQuality.kbps320,
        ),
        'video.mp3',
      );
      expect(p.codec, 'mp3');
    });

    test('compress strong is mono 64 kbps', () async {
      final p = await render(
        AudioJob.single(
          source: await source('music.m4a'),
          format: AudioOutputFormat.mp3,
          quality: AudioCompression.strong.quality,
          mono: AudioCompression.strong.mono,
        ),
        'compressed.mp3',
      );
      expect(p.channels, 1);
    });

    for (final mode in CleanupMode.values) {
      test('clean: ${mode.name} (mono and stereo sources)', () async {
        for (final name in ['voice.wav', 'song.mp3']) {
          await render(
            AudioJob.single(
              source: await source(name),
              cleanup: CleanupSettings(mode, NoiseStrength.strong),
              format: AudioOutputFormat.m4a,
            ),
            'clean_${mode.name}_$name.m4a',
          );
        }
      });
    }

    test('merge joins different sample rates / channel counts', () async {
      await render(
        AudioJob.merge(
          sources: [await source('voice.wav'), await source('music.m4a'), await source('a.mp4')],
          format: AudioOutputFormat.mp3,
        ),
        'merge.mp3',
      );
    });

    test('merge with cross-fade and speed', () async {
      await render(
        AudioJob.merge(
          sources: [await source('song.mp3'), await source('music.m4a'), await source('voice.wav')],
          crossfade: const Duration(seconds: 2),
          speed: 1.25,
          fadeOut: const Duration(seconds: 2),
          format: AudioOutputFormat.m4a,
        ),
        'merge_xfade.m4a',
      );
    });

    test('mix layers tracks with envelope, trim and offset', () async {
      final song = await source('song.mp3');
      final music = await source('music.m4a');
      final voice = await source('voice.wav');
      await render(
        AudioJob.mix(
          tracks: [
            MixTrack(path: song.path, name: 'song', sourceDuration: song.duration,
                envelope: VolumeEnvelope.dip),
            MixTrack(path: music.path, name: 'music', sourceDuration: music.duration,
                volume: 0.4, trimStart: const Duration(seconds: 1),
                trimEnd: const Duration(seconds: 4), envelope: VolumeEnvelope.fadeInOut),
            MixTrack(path: voice.path, name: 'voice', sourceDuration: voice.duration,
                start: const Duration(seconds: 2), volume: 1.5),
          ],
          format: AudioOutputFormat.mp3,
        ),
        'mix.mp3',
      );
    });

    test('mix longest + arrange one after another', () async {
      final song = await source('song.mp3');
      final voice = await source('voice.wav');
      await render(
        AudioJob.mix(
          tracks: [
            MixTrack(path: voice.path, name: 'voice', sourceDuration: voice.duration),
            MixTrack(path: song.path, name: 'song', sourceDuration: song.duration,
                start: voice.duration + const Duration(seconds: 1)),
          ],
          mixLength: MixLength.longest,
          format: AudioOutputFormat.wav,
        ),
        'arrange.wav',
      );
    });

    test('mix loops a short background under the main track', () async {
      final music = await source('music.m4a');
      final voice = await source('voice.wav');
      await render(
        AudioJob.mix(
          tracks: [
            MixTrack(path: music.path, name: 'music', sourceDuration: music.duration),
            MixTrack(path: voice.path, name: 'voice', sourceDuration: voice.duration,
                volume: 0.3),
          ],
          loopShorter: true,
          format: AudioOutputFormat.m4a,
        ),
        'mix_loop.m4a',
      );
    });

    test('waveform PCM decode + peaks', () async {
      final path = '${out.path}/wave.raw';
      final r = await Process.run(
        _ffmpeg!,
        builder.buildPcm(input: media('a.mp4'), output: path, sampleRate: 4000),
      );
      expect(r.exitCode, 0, reason: '${r.stderr}');
      final peaks = computePeaks(await File(path).readAsBytes());
      expect(peaks, hasLength(WaveformService.buckets));
      expect(peaks.reduce((a, b) => a > b ? a : b), closeTo(1, 1e-9));
    });
  });
}
