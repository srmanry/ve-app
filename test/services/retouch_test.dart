import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:video_editor_app/domain/entities/image_edit.dart';
import 'package:video_editor_app/services/image/image_renderer.dart';
import 'package:video_editor_app/services/image/spot_healer.dart';

/// Skin-like noisy texture (seeded) with a dark blemish at (50, 50).
Uint8List _skin(int w, int h) {
  final rnd = math.Random(1);
  final px = Uint8List(w * h * 4);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final i = (y * w + x) * 4;
      final n = rnd.nextInt(16) - 8;
      final spot = math.sqrt(math.pow(x - 50, 2) + math.pow(y - 50, 2)) < 5;
      px[i] = spot ? 70 : 220 + n;
      px[i + 1] = spot ? 40 : 170 + n;
      px[i + 2] = spot ? 30 : 140 + n;
      px[i + 3] = 255;
    }
  }
  return px;
}

int _red(Uint8List px, int w, int x, int y) => px[(y * w + x) * 4];

Future<List<int>> _pixel(ui.Image img, int x, int y) async {
  final d = (await img.toByteData())!;
  final i = (y * img.width + x) * 4;
  return [d.getUint8(i), d.getUint8(i + 1), d.getUint8(i + 2), d.getUint8(i + 3)];
}

void main() {
  test('heal removes a blemish and leaves the rest alone', () {
    const w = 120, h = 100;
    final src = _skin(w, h);
    final out = healSpots(HealJob(src, w, h, const [(50, 50, 8)]));
    expect(_red(src, w, 50, 50), 70);
    expect(_red(out, w, 50, 50), inInclusiveRange(200, 240), reason: 'spot now matches the skin');
    // Far away pixels are untouched.
    expect(_red(out, w, 110, 90), _red(src, w, 110, 90));
    // Source buffer not modified.
    expect(_red(src, w, 50, 50), 70);
  });

  test('heal near the border does not crash', () {
    const w = 40, h = 30;
    final out = healSpots(HealJob(_skin(w, h), w, h, const [(1, 1, 12), (39, 29, 6)]));
    expect(out.length, w * h * 4);
  });

  test('sourceFromOutput inverts rotation, flip and crop', () {
    // Rotated right: the output's top-left corner is the source's bottom-left.
    expect(const ImageEdit(quarterTurns: 1).sourceFromOutput(0, 0), (0.0, 1.0));
    expect(const ImageEdit(quarterTurns: 3).sourceFromOutput(0, 0), (1.0, 0.0));
    expect(const ImageEdit(flipX: true).sourceFromOutput(0.25, 0.5), (0.75, 0.5));
    final cropped = const ImageEdit(crop: CropRect(0.5, 0, 1, 0.5)).sourceFromOutput(0, 0);
    expect(cropped, (0.5, 0.0));
  });

  testWidgets('rendered rotation matches sourceFromOutput', (tester) async {
    await tester.runAsync(() async {
      // 40×20 photo, a white dot at source (30, 4).
      final px = Uint8List(40 * 20 * 4);
      for (var i = 0; i < 40 * 20; i++) {
        px[i * 4 + 3] = 255;
      }
      for (var y = 3; y <= 5; y++) {
        for (var x = 29; x <= 31; x++) {
          final i = (y * 40 + x) * 4;
          px[i] = px[i + 1] = px[i + 2] = 255;
        }
      }
      final photo = await ImageRenderer.decodeRgba(px, 40, 20);
      for (final turns in [1, 2, 3]) {
        final edit = ImageEdit(quarterTurns: turns, flipX: turns == 2);
        final png = await ImageRenderer.renderPng(ImageLayers(photo: photo), edit);
        final img = await ImageRenderer.decodeFile(png);
        // Find the dot in the output and map it back.
        final data = (await img.toByteData())!;
        var found = false;
        for (var y = 0; y < img.height && !found; y++) {
          for (var x = 0; x < img.width && !found; x++) {
            if (data.getUint8((y * img.width + x) * 4) > 200) {
              final (sx, sy) = edit.sourceFromOutput((x + 0.5) / img.width, (y + 0.5) / img.height);
              expect((sx * 40 - 30).abs(), lessThan(2.5), reason: 'turns $turns x');
              expect((sy * 20 - 4).abs(), lessThan(2.5), reason: 'turns $turns y');
              found = true;
            }
          }
        }
        expect(found, isTrue);
      }
    });
  });

  testWidgets('brighten stroke only changes the painted area; text renders', (tester) async {
    await tester.runAsync(() async {
      final px = Uint8List(100 * 100 * 4);
      for (var i = 0; i < 100 * 100; i++) {
        px[i * 4] = px[i * 4 + 1] = px[i * 4 + 2] = 100;
        px[i * 4 + 3] = 255;
      }
      final photo = await ImageRenderer.decodeRgba(px, 100, 100);
      final edit = const ImageEdit(
        retouch: [
          RetouchStroke(tool: RetouchTool.brighten, points: [(0.25, 0.25)], radius: 0.1, strength: 1),
        ],
        texts: [PhotoText(id: 't', text: 'HI', x: 0.75, y: 0.75, size: 0.2, color: 0xFFFF0000)],
        vignette: 0.5,
      );
      final out = await ImageRenderer.decodeFile(
        await ImageRenderer.renderPng(ImageLayers(photo: photo), edit),
      );
      expect((await _pixel(out, 25, 25))[0], greaterThan(130), reason: 'brightened');
      expect((await _pixel(out, 50, 50))[0], inInclusiveRange(95, 105), reason: 'centre untouched');
      expect((await _pixel(out, 1, 1))[0], lessThan(90), reason: 'vignette darkens corners');
      // Some red text pixels around (75, 75).
      var red = 0;
      for (var y = 62; y < 88; y++) {
        for (var x = 60; x < 92; x++) {
          final p = await _pixel(out, x, y);
          if (p[0] > 180 && p[1] < 80) red++;
        }
      }
      expect(red, greaterThan(10));
    });
  });

  testWidgets('applyHeals heals at any resolution', (tester) async {
    await tester.runAsync(() async {
      const w = 120, h = 100;
      final photo = await ImageRenderer.decodeRgba(_skin(w, h), w, h);
      final edit = const ImageEdit(
        retouch: [RetouchStroke(tool: RetouchTool.heal, points: [(50 / 120, 0.5)], radius: 8 / 120)],
      );
      final healed = await ImageRenderer.applyHeals(photo, edit);
      expect((await _pixel(healed, 50, 50))[0], greaterThan(190));
    });
  });
}
