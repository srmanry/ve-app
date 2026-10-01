import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_editor_app/services/ffmpeg/ffmpeg_command_builder.dart';
import 'package:video_editor_app/domain/entities/image_edit.dart';
import 'package:video_editor_app/services/image/document_scan.dart';
import 'package:video_editor_app/services/image/pdf_writer.dart';
import 'package:video_editor_app/services/video/video_processing_service.dart';

/// Dark table (40) with a tilted white page; the page has a black square
/// near its top-left corner.
(Uint8List, Quad) _photo(int w, int h) {
  const quad = [(0.2, 0.15), (0.85, 0.1), (0.9, 0.85), (0.15, 0.9)];
  final px = Uint8List(w * h * 4);
  bool inside(double x, double y) {
    // Point in convex polygon (all cross products same sign).
    for (var i = 0; i < 4; i++) {
      final (x1, y1) = quad[i];
      final (x2, y2) = quad[(i + 1) % 4];
      if ((x2 - x1) * (y - y1) - (y2 - y1) * (x - x1) < 0) return false;
    }
    return true;
  }

  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final i = (y * w + x) * 4;
      final v = inside((x + 0.5) / w, (y + 0.5) / h) ? 235 : 40;
      px[i] = px[i + 1] = px[i + 2] = v;
      px[i + 3] = 255;
    }
  }
  return (px, quad);
}

void main() {
  test('detects the page corners on a dark table', () {
    const w = 200, h = 160;
    final (px, quad) = _photo(w, h);
    final found = detectDocument(DetectJob(px, w, h))!;
    for (var i = 0; i < 4; i++) {
      expect((found[i].$1 - quad[i].$1).abs(), lessThan(0.03), reason: 'corner $i x');
      expect((found[i].$2 - quad[i].$2).abs(), lessThan(0.03), reason: 'corner $i y');
    }
  });

  test('no page on a plain photo', () {
    final px = Uint8List(50 * 50 * 4)..fillRange(0, 50 * 50 * 4, 120);
    expect(detectDocument(DetectJob(px, 50, 50)), isNull);
  });

  test('warp straightens the page: every output pixel is paper', () {
    const w = 200, h = 160;
    final (px, quad) = _photo(w, h);
    final (ow, oh) = pageSize(quad, w, h);
    final out = warpPage(WarpJob(px, w, h, quad, ow, oh));
    var dark = 0;
    for (var i = 0; i < ow * oh; i++) {
      if (out[i * 4] < 128) dark++;
    }
    // Only bilinear fringe at the very edge may touch the table.
    expect(dark / (ow * oh), lessThan(0.03));
    final (lo, hi) = pageLevels(out);
    expect(hi, greaterThan(200));
    expect(lo, lessThan(hi));
  });

  test('PDF opens in a real PDF reader', () async {
    final ffmpeg = Platform.environment['FFMPEG_BIN'];
    if (ffmpeg == null || !Platform.isMacOS) {
      markTestSkipped('needs FFMPEG_BIN on macOS');
      return;
    }
    final dir = Directory.systemTemp.createTempSync('pdf_test');
    final pages = <PdfPage>[];
    for (final (w, h) in [(1240, 1754), (1754, 1240)]) {
      final png = '${dir.path}/p.png', jpg = '${dir.path}/p.jpg';
      Process.runSync(ffmpeg, ['-v', 'error', '-y', '-f', 'lavfi', '-i', 'testsrc2=size=${w}x$h', '-frames:v', '1', png]);
      final r = Process.runSync(
        ffmpeg,
        const FfmpegCommandBuilder().buildImage(
          ImageJob(input: png, width: w, height: h, format: ImageFormat.jpg, quality: 80),
          jpg,
        ),
      );
      expect(r.exitCode, 0, reason: '${r.stderr}');
      pages.add(PdfPage(File(jpg).readAsBytesSync(), w, h));
    }
    final pdf = '${dir.path}/scan.pdf';
    File(pdf).writeAsBytesSync(buildPdf(pages));
    final script = '${dir.path}/check.swift';
    File(script).writeAsStringSync('''
import PDFKit
let doc = PDFDocument(url: URL(fileURLWithPath: CommandLine.arguments[1]))!
var sizes: [String] = []
for i in 0..<doc.pageCount { let b = doc.page(at: i)!.bounds(for: .mediaBox); sizes.append("\\(Int(b.width))x\\(Int(b.height))") }
print("\\(doc.pageCount) \\(sizes.joined(separator: ","))")
''');
    final r = Process.runSync('swift', [script, pdf]);
    expect(r.exitCode, 0, reason: '${r.stderr}');
    expect((r.stdout as String).trim(), '2 595x841,841x595');
    dir.deleteSync(recursive: true);
  }, timeout: const Timeout(Duration(minutes: 3)));
}
