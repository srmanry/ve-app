import 'package:flutter_test/flutter_test.dart';
import 'package:video_editor_app/core/utils/formatters.dart';
import 'package:video_editor_app/core/utils/stable_hash.dart';
import 'package:video_editor_app/domain/entities/color_adjustments.dart';
import 'package:video_editor_app/services/ffmpeg/ffmpeg_error_mapper.dart';
import 'package:video_editor_app/core/errors/app_exception.dart';
import 'package:video_editor_app/services/ffmpeg/media_info_parser.dart';
import 'package:video_editor_app/services/video/color_matrix.dart';

List<double> apply(List<double> m, List<double> rgb) => [
      for (var r = 0; r < 3; r++)
        m[r * 5] * rgb[0] + m[r * 5 + 1] * rgb[1] + m[r * 5 + 2] * rgb[2] + m[r * 5 + 4],
    ];

void main() {
  group('ColorMatrix', () {
    test('original + neutral is identity', () {
      expect(ColorMatrix.isIdentity(
          ColorMatrix.build(FilterPreset.original, 1, ColorAdjustments.neutral)), isTrue);
    });

    test('zero strength disables the preset', () {
      expect(ColorMatrix.isIdentity(
          ColorMatrix.build(FilterPreset.sepia, 0, ColorAdjustments.neutral)), isTrue);
    });

    test('grayscale produces equal channels', () {
      final m = ColorMatrix.build(FilterPreset.grayscale, 1, ColorAdjustments.neutral);
      final out = apply(m, [200, 50, 10]);
      expect(out[0], closeTo(out[1], 1e-6));
      expect(out[1], closeTo(out[2], 1e-6));
    });

    test('multiply applies right-hand matrix first', () {
      final a = ColorMatrix.brightness(0.2); // +0.2 * 0.25 * 255 = +12.75
      final b = ColorMatrix.exposure(1); // x2
      final out = apply(ColorMatrix.multiply(a, b), [10, 10, 10]);
      expect(out[0], closeTo(10 * 2 + 12.75, 1e-6));
    });

    test('warm raises red and lowers blue', () {
      final out = apply(ColorMatrix.build(FilterPreset.warm, 1, ColorAdjustments.neutral), [128, 128, 128]);
      expect(out[0], greaterThan(128));
      expect(out[2], lessThan(128));
    });
  });

  group('MediaInfoParser', () {
    test('reads phone-style portrait video with negative rotation', () {
      final info = MediaInfoParser.parse({
        'format': {'duration': '12.5', 'size': '123456', 'format_name': 'mov,mp4'},
        'streams': [
          {
            'codec_type': 'video', 'codec_name': 'hevc', 'width': 1920, 'height': 1080,
            'avg_frame_rate': '30000/1001',
            'side_data_list': [{'side_data_type': 'Display Matrix', 'rotation': -90}],
          },
          {'codec_type': 'audio', 'codec_name': 'aac'},
        ],
      })!;
      expect(info.duration, const Duration(milliseconds: 12500));
      expect(info.rotation, 270);
      expect(info.displayWidth, 1080);
      expect(info.frameRate, closeTo(29.97, 0.01));
      expect(info.hasAudio, isTrue);
      expect(info.fileSize, 123456);
    });

    test('ignores cover art in audio files', () {
      final info = MediaInfoParser.parse({
        'format': {'duration': '200'},
        'streams': [
          {'codec_type': 'audio', 'codec_name': 'mp3'},
          {'codec_type': 'video', 'codec_name': 'mjpeg', 'disposition': {'attached_pic': 1}},
        ],
      })!;
      expect(info.hasVideo, isFalse);
    });

    test('returns null for files without usable streams or duration', () {
      expect(MediaInfoParser.parse({'format': {}, 'streams': []}), isNull);
      expect(MediaInfoParser.parse({
        'format': {'duration': 'N/A'},
        'streams': [{'codec_type': 'video'}],
      }), isNull);
    });
  });

  group('FfmpegErrorMapper', () {
    AppErrorKind kind(String log) => FfmpegErrorMapper.map(log,
        fallbackKind: AppErrorKind.exportFailed, fallbackMessage: 'x').kind;

    test('classifies common failures', () {
      expect(kind('av_interleaved_write_frame(): No space left on device'), AppErrorKind.insufficientStorage);
      expect(kind('/a.mp4: No such file or directory'), AppErrorKind.missingSourceFile);
      expect(kind('moov atom not found'), AppErrorKind.corruptedFile);
      expect(kind('Decoder not found'), AppErrorKind.unsupportedCodec);
      expect(kind('something else'), AppErrorKind.exportFailed);
    });

    test('never exposes raw logs in the message', () {
      final e = FfmpegErrorMapper.map('[libx264 @ 0x1] secret internals',
          fallbackKind: AppErrorKind.exportFailed, fallbackMessage: 'Friendly');
      expect(e.message, 'Friendly');
      expect(e.debugDetails, contains('libx264'));
    });
  });

  group('utils', () {
    test('formatters', () {
      expect(Formatters.duration(const Duration(seconds: 75)), '01:15');
      expect(Formatters.duration(const Duration(seconds: 3725)), '1:02:05');
      expect(Formatters.duration(const Duration(milliseconds: 1540), showTenths: true), '00:01.5');
      expect(Formatters.fileSize(1536), '1.50 KB');
      expect(Formatters.fileSize(250 * 1024 * 1024), '250 MB');
    });

    test('stableHash is deterministic and distinguishes inputs', () {
      expect(stableHash('abc'), stableHash('abc'));
      expect(stableHash('abc'), isNot(stableHash('abd')));
      expect(stableHash('abc'), hasLength(16));
    });
  });
}
