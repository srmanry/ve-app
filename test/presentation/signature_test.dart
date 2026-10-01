import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_editor_app/presentation/image/signature_screen.dart';

/// Applies a 4×5 colour matrix to one RGBA pixel.
List<int> _apply(List<double> m, List<int> px) => [
  for (var r = 0; r < 4; r++)
    (m[r * 5] * px[0] + m[r * 5 + 1] * px[1] + m[r * 5 + 2] * px[2] + m[r * 5 + 3] * px[3] + m[r * 5 + 4])
        .round()
        .clamp(0, 255),
];

void main() {
  const lo = 73.6, hi = 183.6; // paper slider at 72%
  const paper = [200, 195, 185, 255], shadowPaper = [190, 186, 178, 255], ink = [40, 40, 60, 255];

  test('paper turns white and ink stays dark (black ink)', () {
    final m = signatureMatrix(lo, hi, InkColor.black);
    expect(_apply(m, paper).sublist(0, 3), everyElement(255));
    expect(_apply(m, shadowPaper).sublist(0, 3), everyElement(255));
    expect(_apply(m, ink).sublist(0, 3), everyElement(lessThan(40)));
  });

  test('blue ink is blue, paper white', () {
    final m = signatureMatrix(lo, hi, InkColor.blue);
    final i = _apply(m, ink);
    expect(i[2], greaterThan(i[0]));
    expect(_apply(m, paper).sublist(0, 3), everyElement(255));
  });

  test('transparent: paper alpha 0, ink opaque', () {
    final m = signatureMatrix(lo, hi, InkColor.black, transparent: true);
    expect(_apply(m, paper)[3], 0);
    expect(_apply(m, ink)[3], 255);
  });

  test('finds the ink and ignores specks', () {
    const w = 200, h = 100;
    final px = Uint8List(w * h * 4)..fillRange(0, w * h * 4, 220);
    void dark(int x, int y) {
      final i = (y * w + x) * 4;
      px[i] = px[i + 1] = px[i + 2] = 30;
    }

    for (var x = 60; x < 140; x++) {
      for (var y = 40; y < 60; y++) {
        dark(x, y);
      }
    }
    dark(5, 5); // a speck of dust
    final c = inkBounds(px, w, h, 128)!;
    expect(c.left * w, inInclusiveRange(48, 60));
    expect(c.right * w, inInclusiveRange(140, 152));
    expect(c.top * h, inInclusiveRange(30, 40));
    expect(inkBounds(Uint8List(16)..fillRange(0, 16, 255), 2, 2, 128), isNull);
  });
}
