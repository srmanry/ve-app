import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_editor_app/domain/entities/id_photo.dart';

void main() {
  bool fits(PrintSheet s) => [...s.main, ...s.extra].every(
    (r) => r.$1 >= 0 && r.$2 >= 0 && r.$1 + r.$3 <= s.width && r.$2 + r.$4 <= s.height,
  );

  bool noOverlap(PrintSheet s) {
    final all = [...s.main, ...s.extra];
    for (var i = 0; i < all.length; i++) {
      for (var j = i + 1; j < all.length; j++) {
        final a = all[i], b = all[j];
        final overlap = a.$1 < b.$1 + b.$3 && b.$1 < a.$1 + a.$3 && a.$2 < b.$2 + b.$4 && b.$2 < a.$2 + a.$4;
        if (overlap) return false;
      }
    }
    return true;
  }

  test('4R sheet: 4 passport + 4 stamp copies', () {
    final p = IdPhotoSize.passport, s = IdPhotoSize.stamp;
    final sheet = PrintSheet.plan(p.widthPx, p.heightPx, stamps: (s.widthPx, s.heightPx));
    expect(sheet.main.length, 4);
    expect(sheet.extra.length, greaterThanOrEqualTo(4));
    expect(fits(sheet), isTrue);
    expect(noOverlap(sheet), isTrue);
  });

  test('4R sheet: stamp-only and 2×2 inch', () {
    final stamps = PrintSheet.plan(IdPhotoSize.stamp.widthPx, IdPhotoSize.stamp.heightPx);
    expect(stamps.count, greaterThanOrEqualTo(16));
    final us = PrintSheet.plan(IdPhotoSize.us.widthPx, IdPhotoSize.us.heightPx);
    expect(us.count, 6, reason: '2×2 in on 4×6 in fits 3×2');
    for (final sh in [stamps, us]) {
      expect(fits(sh), isTrue);
      expect(noOverlap(sh), isTrue);
    }
  });

  test('ID crop frames head and shoulders', () {
    // 100×100 mask: head circle at (60, 30) r=12, shoulders block below.
    const n = 100;
    final m = Uint8List(n * n);
    for (var y = 0; y < n; y++) {
      for (var x = 0; x < n; x++) {
        final head = (x - 60) * (x - 60) + (y - 30) * (y - 30) < 144;
        final body = y > 45 && x > 35 && x < 85;
        if (head || body) m[y * n + x] = 255;
      }
    }
    final c = idPhotoCrop(m, n, n, 1000, 1000, 45 / 55)!;
    // Head top (y = 18) is just inside the top edge.
    expect(c.top, lessThan(0.18));
    expect(c.top, greaterThan(0.1));
    // Head centred horizontally.
    expect((c.left + c.right) / 2, closeTo(0.6, 0.03));
    // Pixel aspect is the passport's.
    expect(c.width / c.height, closeTo(45 / 55, 0.01));
  });

  test('no person → null', () {
    expect(idPhotoCrop(Uint8List(16), 4, 4, 100, 100, 1), isNull);
  });
}
