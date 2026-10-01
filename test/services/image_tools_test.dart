import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:video_editor_app/domain/entities/image_edit.dart';
import 'package:video_editor_app/services/export/export_service.dart';
import 'package:video_editor_app/services/ffmpeg/ffmpeg_command_builder.dart';
import 'package:video_editor_app/services/image/image_renderer.dart';
import 'package:video_editor_app/services/video/video_processing_service.dart';

/// 40×20 photo: left half red, right half blue.
Future<ui.Image> _photo() {
  final rgba = Uint8List(40 * 20 * 4);
  for (var y = 0; y < 20; y++) {
    for (var x = 0; x < 40; x++) {
      final i = (y * 40 + x) * 4;
      rgba[i] = x < 20 ? 255 : 0;
      rgba[i + 2] = x < 20 ? 0 : 255;
      rgba[i + 3] = 255;
    }
  }
  return ImageRenderer.decodeRgba(rgba, 40, 20);
}

Future<List<int>> _pixel(Uint8List png, int x, int y) async {
  final img = await ImageRenderer.decodeFile(png);
  final data = (await img.toByteData())!;
  final i = (y * img.width + x) * 4;
  return [data.getUint8(i), data.getUint8(i + 1), data.getUint8(i + 2), data.getUint8(i + 3)];
}

void main() {
  test('centered crop keeps the requested pixel aspect', () {
    final c = CropRect.centered(1, 4000, 3000);
    expect(c.width * 4000, closeTo(c.height * 3000, 1e-6));
    expect(c.top, 0);
  });

  test('resize never upscales and keeps even sizes', () {
    expect(ResizePreset.fullHd.apply(4000, 3000), (1920, 1440));
    expect(ResizePreset.fullHd.apply(800, 600), (800, 600));
    expect(ResizePreset.half.apply(1001, 601), (500, 300));
  });

  test('photo size presets resolve to print pixels at 300 DPI', () {
    final passport = PhotoSizePreset.passport.targetFor(3000, 4000);
    expect((passport.width, passport.height), (531, 650));
    expect(passport.dpi, 300);
    expect(passport.anchorY, lessThan(0.5));
    final sig = PhotoSizePreset.signature.targetFor(1000, 400);
    expect((sig.width, sig.height, sig.maxBytes, sig.dpi), (300, 80, 60 * 1024, null));
    // Prints follow the photo's orientation.
    final r4 = PhotoSizePreset.print4r.targetFor(4000, 3000);
    expect((r4.width, r4.height), (1800, 1200));
    expect(toPixels(25.4, SizeUnit.mm), 300);
  });

  test('fit-inside custom target keeps the shape', () {
    const t = ResizeTarget(width: 1000, height: 1000, fill: false);
    expect(t.sizeFor(4000, 2000), (1000, 500));
  });

  test('jpeg DPI is written into the JFIF header', () {
    final jpeg = Uint8List.fromList([
      0xFF, 0xD8, 0xFF, 0xE0, 0, 16, 0x4A, 0x46, 0x49, 0x46, 0, 1, 1, 0, 0, 1, 0, 1, 0, 0,
    ]);
    final out = jpegWithDpi(jpeg, 300)!;
    expect(out.sublist(13, 18), [1, 1, 44, 1, 44]);
    expect(jpegWithDpi(Uint8List.fromList([1, 2, 3]), 300), isNull);
  });

  test('jpg output is flattened on white; webp keeps alpha', () {
    const b = FfmpegCommandBuilder();
    final jpg = b.buildImage(
      const ImageJob(input: '/i.png', width: 100, height: 50, format: ImageFormat.jpg, quality: 100),
      '/o.jpg',
    );
    expect(jpg.join(' '), contains('color=c=white:s=100x50'));
    expect(jpg, containsAllInOrder(['-q:v', '2']));
    final webp = b.buildImage(
      const ImageJob(input: '/i.png', width: 100, height: 50, format: ImageFormat.webp, quality: 80),
      '/o.webp',
    );
    expect(webp.join(' '), isNot(contains('white')));
    expect(webp, containsAllInOrder(['-c:v', 'libwebp', '-quality', '80']));
  });

  testWidgets('render: rotate right then crop the top half', (tester) async {
    await tester.runAsync(() async {
      final photo = await _photo();
      final edit = const ImageEdit(quarterTurns: 1, crop: CropRect(0, 0, 1, 0.5));
      // Rotated photo is 20×40 with red on top; the top half is all red.
      expect(ImageRenderer.outputSize(edit, 40, 20), (20, 20));
      final png = await ImageRenderer.renderPng(ImageLayers(photo: photo), edit);
      expect(await _pixel(png, 10, 10), [255, 0, 0, 255]);
    });
  });

  testWidgets('render: flip and transparent cut-out', (tester) async {
    await tester.runAsync(() async {
      final photo = await _photo();
      // Mask keeps only the left (red) half of the source.
      final gray = Uint8List(4 * 2);
      gray[0] = gray[1] = gray[4] = gray[5] = 255;
      final mask = await ImageRenderer.maskImage(gray, 4, 2);
      final png = await ImageRenderer.renderPng(
        ImageLayers(photo: photo, mask: mask),
        const ImageEdit(cutout: true),
      );
      expect((await _pixel(png, 5, 10))[3], 255);
      expect((await _pixel(png, 35, 10))[3], 0);

      final flipped = await ImageRenderer.renderPng(ImageLayers(photo: photo), const ImageEdit(flipX: true));
      expect(await _pixel(flipped, 5, 10), [0, 0, 255, 255]);
    });
  });

  group('real ffmpeg', skip: Platform.environment['FFMPEG_BIN'] == null ? 'FFMPEG_BIN not set' : null, () {
    testWidgets('encodes jpg / png / webp at the requested size', (tester) async {
      final ffmpeg = Platform.environment['FFMPEG_BIN']!;
      final dir = Directory.systemTemp.createTempSync('img_test');
      final src = '${dir.path}/src.png';
      var r = Process.runSync(ffmpeg, [
        '-v', 'error', '-y', '-f', 'lavfi', '-i',
        'color=c=red@0.0:size=1200x900,format=rgba,drawbox=x=300:y=200:w=600:h=500:color=blue@1:t=fill',
        '-frames:v', '1', src,
      ]);
      expect(r.exitCode, 0, reason: '${r.stderr}');
      for (final f in ImageFormat.values) {
        final out = '${dir.path}/o.${f.extension}';
        r = Process.runSync(
          ffmpeg,
          const FfmpegCommandBuilder().buildImage(
            ImageJob(input: src, width: 600, height: 450, format: f, quality: 80),
            out,
          ),
        );
        expect(r.exitCode, 0, reason: '${f.name}: ${r.stderr}');
        // Decode with Flutter (the same codecs the phone uses).
        final png = File(out).readAsBytesSync();
        late List<int> px;
        late int width;
        await tester.runAsync(() async {
          final img = await ImageRenderer.decodeFile(png);
          width = img.width;
          final data = (await img.toByteData())!;
          px = [data.getUint8(0), data.getUint8(1), data.getUint8(2), data.getUint8(3)];
        });
        expect(width, 600);
        if (f == ImageFormat.jpg) {
          expect(px[0], greaterThan(240), reason: 'jpg corner should be white');
          expect(px[1], greaterThan(240), reason: 'jpg corner should be white');
        } else {
          expect(px[3], lessThan(10), reason: '${f.name} corner should stay transparent');
        }
      }

      // Passport crop from a portrait photo: exact size, real DPI in the file.
      final face = '${dir.path}/face.png';
      Process.runSync(ffmpeg, ['-v', 'error', '-y', '-f', 'lavfi', '-i', 'testsrc2=size=768x1360', '-frames:v', '1', face]);
      final t = PhotoSizePreset.passport.targetFor(768, 1360);
      for (final f in [ImageFormat.jpg, ImageFormat.png]) {
        final out = '${dir.path}/passport.${f.extension}';
        r = Process.runSync(
          ffmpeg,
          const FfmpegCommandBuilder().buildImage(
            ImageJob(input: face, width: t.width, height: t.height, format: f, fill: true,
                anchorY: t.anchorY, dpi: t.dpi),
            out,
          ),
        );
        expect(r.exitCode, 0, reason: '${r.stderr}');
        var bytes = File(out).readAsBytesSync();
        if (f == ImageFormat.jpg) {
          bytes = jpegWithDpi(bytes, 300)!;
          expect(bytes[13], 1);
        } else {
          // PNG pHYs chunk: 300 DPI = 11811 px/m.
          final s = String.fromCharCodes(bytes);
          expect(s.contains('pHYs'), isTrue);
        }
        await tester.runAsync(() async {
          final img = await ImageRenderer.decodeFile(bytes);
          expect((img.width, img.height), (531, 650));
        });
      }

      // A chosen part (right half = blue) is what ends up in the output.
      final halves = '${dir.path}/halves.png';
      Process.runSync(ffmpeg, [
        '-v', 'error', '-y', '-f', 'lavfi', '-i', 'color=c=red:size=400x200',
        '-vf', 'drawbox=x=200:y=0:w=200:h=200:color=blue:t=fill', '-frames:v', '1', halves,
      ]);
      final picked = '${dir.path}/picked.png';
      r = Process.runSync(
        ffmpeg,
        const FfmpegCommandBuilder().buildImage(
          const ImageJob(input: '', width: 100, height: 100, format: ImageFormat.png, fill: true,
              crop: CropRect(0.5, 0, 1, 1)),
          picked,
        ).map((a) => a.isEmpty ? halves : a).toList(),
      );
      expect(r.exitCode, 0, reason: '${r.stderr}');
      await tester.runAsync(() async {
        final img = await ImageRenderer.decodeFile(File(picked).readAsBytesSync());
        final data = (await img.toByteData())!;
        expect((img.width, img.height), (100, 100));
        expect(data.getUint8(0), lessThan(5), reason: 'left edge should be blue, not red');
        expect(data.getUint8(2), greaterThan(250), reason: 'left edge should be blue');
      });
      // "Under 100 KB" from a busy 12 MP photo, and an exact-size photo
      // that must keep its dimensions.
      final busy = '${dir.path}/busy.png';
      Process.runSync(ffmpeg, ['-v', 'error', '-y', '-f', 'lavfi', '-i', 'cellauto=s=4000x3000:rule=110', '-frames:v', '1', busy]);
      for (final (w, h, fill, limit) in [(4000, 3000, false, 100 * 1024), (531, 650, true, 30 * 1024)]) {
        final out = '${dir.path}/fit.jpg';
        final (fw, fh, q) = await encodeWithinLimit(
          width: w,
          height: h,
          quality: 90,
          limit: limit,
          canShrink: !fill,
          encode: (ew, eh, eq) async {
            final res = Process.runSync(
              ffmpeg,
              const FfmpegCommandBuilder().buildImage(
                ImageJob(input: busy, width: ew, height: eh, format: ImageFormat.jpg, quality: eq, fill: fill),
                out,
              ),
            );
            expect(res.exitCode, 0, reason: '${res.stderr}');
            return File(out).lengthSync();
          },
        );
        expect(File(out).lengthSync(), lessThanOrEqualTo(limit), reason: '$w×$h → $fw×$fh q$q');
        if (fill) expect((fw, fh), (w, h), reason: 'exact sizes are never shrunk');
      }
      dir.deleteSync(recursive: true);
    });
  });
}
