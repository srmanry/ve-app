import 'dart:convert';
import 'dart:typed_data';

/// One page: a JPEG (RGB) and its pixel size.
class PdfPage {
  const PdfPage(this.jpeg, this.width, this.height);
  final Uint8List jpeg;
  final int width;
  final int height;
}

/// Writes a PDF with one A4 page per image (landscape for wide images),
/// each image fitted and centred. JPEGs are embedded as-is (DCTDecode), so
/// there is no quality loss and no PDF library is needed.
Uint8List buildPdf(List<PdfPage> pages, {double margin = 0}) {
  const a4w = 595.28, a4h = 841.89;
  final out = BytesBuilder(copy: false);
  final offsets = <int>[];
  void write(String s) => out.add(latin1.encode(s));
  void obj(int id, void Function() body) {
    offsets.add(out.length);
    write('$id 0 obj\n');
    body();
    write('\nendobj\n');
  }

  String n(double v) => v.toStringAsFixed(2);

  write('%PDF-1.4\n%âãÏÓ\n');
  final pageIds = [for (var i = 0; i < pages.length; i++) 3 + i * 3];
  obj(1, () => write('<< /Type /Catalog /Pages 2 0 R >>'));
  obj(2, () => write('<< /Type /Pages /Kids [${pageIds.map((id) => '$id 0 R').join(' ')}] /Count ${pages.length} >>'));
  for (var i = 0; i < pages.length; i++) {
    final pg = pages[i];
    final landscape = pg.width > pg.height;
    final pw = landscape ? a4h : a4w, ph = landscape ? a4w : a4h;
    final k = [(pw - 2 * margin) / pg.width, (ph - 2 * margin) / pg.height].reduce((a, b) => a < b ? a : b);
    final iw = pg.width * k, ih = pg.height * k;
    final x = (pw - iw) / 2, y = (ph - ih) / 2;
    final id = pageIds[i];
    obj(id, () {
      write(
        '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 ${n(pw)} ${n(ph)}] '
        '/Resources << /XObject << /Im0 ${id + 2} 0 R >> >> /Contents ${id + 1} 0 R >>',
      );
    });
    final content = 'q ${n(iw)} 0 0 ${n(ih)} ${n(x)} ${n(y)} cm /Im0 Do Q';
    obj(id + 1, () => write('<< /Length ${content.length} >>\nstream\n$content\nendstream'));
    obj(id + 2, () {
      write(
        '<< /Type /XObject /Subtype /Image /Width ${pg.width} /Height ${pg.height} '
        '/ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode /Length ${pg.jpeg.length} >>\nstream\n',
      );
      out.add(pg.jpeg);
      write('\nendstream');
    });
  }
  final xref = out.length;
  final count = offsets.length + 1;
  write('xref\n0 $count\n0000000000 65535 f \n');
  for (final o in offsets) {
    write('${o.toString().padLeft(10, '0')} 00000 n \n');
  }
  write('trailer\n<< /Size $count /Root 1 0 R >>\nstartxref\n$xref\n%%EOF\n');
  return out.takeBytes();
}
