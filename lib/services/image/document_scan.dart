import 'dart:collection';
import 'dart:math' as math;
import 'dart:typed_data';

/// A document's four corners as fractions of the photo, in order
/// top-left, top-right, bottom-right, bottom-left.
typedef Quad = List<(double, double)>;

/// Corners slightly inside the photo edges (when nothing is detected).
const Quad defaultQuad = [(0.04, 0.04), (0.96, 0.04), (0.96, 0.96), (0.04, 0.96)];

/// Small grayscale copy of a photo for [detectDocument].
class DetectJob {
  const DetectJob(this.rgba, this.width, this.height);
  final Uint8List rgba;
  final int width;
  final int height;
}

/// Finds a sheet of paper lying on a darker surface: Otsu threshold, the
/// largest bright region, then its extreme corners. Returns null when no
/// clear page is found (the user places the corners by hand).
Quad? detectDocument(DetectJob job) {
  final w = job.width, h = job.height, n = w * h;
  if (n == 0) return null;
  final gray = Uint8List(n);
  final hist = List<int>.filled(256, 0);
  for (var i = 0; i < n; i++) {
    final g = (0.299 * job.rgba[i * 4] + 0.587 * job.rgba[i * 4 + 1] + 0.114 * job.rgba[i * 4 + 2]).round();
    gray[i] = g;
    hist[g]++;
  }
  // Otsu: the threshold that best separates paper from background.
  var sum = 0.0;
  for (var t = 0; t < 256; t++) {
    sum += t * hist[t];
  }
  var sumB = 0.0, wB = 0, best = 0.0, threshold = 128;
  for (var t = 0; t < 256; t++) {
    wB += hist[t];
    if (wB == 0) continue;
    final wF = n - wB;
    if (wF == 0) break;
    sumB += t * hist[t];
    final mB = sumB / wB, mF = (sum - sumB) / wF;
    final between = wB * wF * (mB - mF) * (mB - mF);
    if (between > best) {
      best = between;
      threshold = t;
    }
  }

  // Largest 4-connected bright region.
  final label = Int32List(n);
  var bestLabel = 0, bestSize = 0, next = 0;
  final queue = Queue<int>();
  for (var start = 0; start < n; start++) {
    if (gray[start] <= threshold || label[start] != 0) continue;
    next++;
    var size = 0;
    label[start] = next;
    queue.add(start);
    while (queue.isNotEmpty) {
      final i = queue.removeFirst();
      size++;
      final x = i % w, y = i ~/ w;
      for (final j in [if (x > 0) i - 1, if (x < w - 1) i + 1, if (y > 0) i - w, if (y < h - 1) i + w]) {
        if (label[j] == 0 && gray[j] > threshold) {
          label[j] = next;
          queue.add(j);
        }
      }
    }
    if (size > bestSize) {
      bestSize = size;
      bestLabel = next;
    }
  }
  // A page should be a good part of the photo but not all of it.
  if (bestSize < n * 0.15 || bestSize > n * 0.985) return null;

  // Extreme points along the diagonals are the corners.
  var tl = (0, 0), tr = (0, 0), br = (0, 0), bl = (0, 0);
  var minSum = 1 << 30, maxSum = -1, minDiff = 1 << 30, maxDiff = -(1 << 30);
  for (var i = 0; i < n; i++) {
    if (label[i] != bestLabel) continue;
    final x = i % w, y = i ~/ w;
    final s = x + y, d = x - y;
    if (s < minSum) (minSum, tl) = (s, (x, y));
    if (s > maxSum) (maxSum, br) = (s, (x, y));
    if (d > maxDiff) (maxDiff, tr) = (d, (x, y));
    if (d < minDiff) (minDiff, bl) = (d, (x, y));
  }
  (double, double) f((int, int) p) => ((p.$1 + 0.5) / w, (p.$2 + 0.5) / h);
  final quad = [f(tl), f(tr), f(br), f(bl)];
  // Reject degenerate shapes (e.g. a thin strip).
  if (_area(quad) < 0.12) return null;
  return quad;
}

double _area(Quad q) {
  var a = 0.0;
  for (var i = 0; i < 4; i++) {
    final (x1, y1) = q[i];
    final (x2, y2) = q[(i + 1) % 4];
    a += x1 * y2 - x2 * y1;
  }
  return a.abs() / 2;
}

/// Output size of a page cut from [quad] on a [w]×[h] photo: the average
/// edge lengths, scaled so the long side is at most [maxSide].
(int, int) pageSize(Quad quad, int w, int h, {int maxSide = 2200}) {
  double len(int a, int b) {
    final dx = (quad[a].$1 - quad[b].$1) * w, dy = (quad[a].$2 - quad[b].$2) * h;
    return math.sqrt(dx * dx + dy * dy);
  }

  var pw = (len(0, 1) + len(3, 2)) / 2;
  var ph = (len(0, 3) + len(1, 2)) / 2;
  final k = math.min(1.0, maxSide / math.max(pw, ph));
  pw *= k;
  ph *= k;
  return (math.max(2, pw.round()), math.max(2, ph.round()));
}

/// Photo pixels and where to cut the page from, for [warpPage].
class WarpJob {
  const WarpJob(this.rgba, this.width, this.height, this.quad, this.outWidth, this.outHeight);
  final Uint8List rgba;
  final int width;
  final int height;
  final Quad quad;
  final int outWidth;
  final int outHeight;
}

/// Straightens the page: maps the output rectangle onto [WarpJob.quad]
/// with a perspective transform and samples bilinearly. Returns RGBA.
Uint8List warpPage(WarpJob job) {
  final ow = job.outWidth, oh = job.outHeight, w = job.width, h = job.height;
  final src = [for (final (x, y) in job.quad) (x * w, y * h)];
  final hm = _homography(
    [(0.0, 0.0), (ow.toDouble(), 0.0), (ow.toDouble(), oh.toDouble()), (0.0, oh.toDouble())],
    src,
  );
  final out = Uint8List(ow * oh * 4);
  final px = job.rgba;
  for (var y = 0; y < oh; y++) {
    for (var x = 0; x < ow; x++) {
      final u = x + 0.5, v = y + 0.5;
      final d = hm[6] * u + hm[7] * v + 1;
      var sx = (hm[0] * u + hm[1] * v + hm[2]) / d - 0.5;
      var sy = (hm[3] * u + hm[4] * v + hm[5]) / d - 0.5;
      sx = sx.clamp(0.0, w - 1.001);
      sy = sy.clamp(0.0, h - 1.001);
      final x0 = sx.floor(), y0 = sy.floor();
      final tx = sx - x0, ty = sy - y0;
      final i00 = (y0 * w + x0) * 4, i10 = i00 + 4, i01 = i00 + w * 4, i11 = i01 + 4;
      final o = (y * ow + x) * 4;
      for (var c = 0; c < 3; c++) {
        final top = px[i00 + c] + (px[i10 + c] - px[i00 + c]) * tx;
        final bottom = px[i01 + c] + (px[i11 + c] - px[i01 + c]) * tx;
        out[o + c] = (top + (bottom - top) * ty).round();
      }
      out[o + 3] = 255;
    }
  }
  return out;
}

/// 3×3 homography (h33 = 1) mapping each [from] point to [to].
List<double> _homography(List<(double, double)> from, List<(double, double)> to) {
  // 8 equations, 8 unknowns.
  final a = List.generate(8, (_) => List<double>.filled(9, 0));
  for (var i = 0; i < 4; i++) {
    final (x, y) = from[i];
    final (u, v) = to[i];
    a[i * 2] = [x, y, 1, 0, 0, 0, -u * x, -u * y, u];
    a[i * 2 + 1] = [0, 0, 0, x, y, 1, -v * x, -v * y, v];
  }
  // Gaussian elimination with partial pivoting.
  for (var c = 0; c < 8; c++) {
    var pivot = c;
    for (var r = c + 1; r < 8; r++) {
      if (a[r][c].abs() > a[pivot][c].abs()) pivot = r;
    }
    final tmp = a[c];
    a[c] = a[pivot];
    a[pivot] = tmp;
    final p = a[c][c];
    if (p.abs() < 1e-12) continue;
    for (var k = c; k < 9; k++) {
      a[c][k] /= p;
    }
    for (var r = 0; r < 8; r++) {
      if (r == c) continue;
      final f = a[r][c];
      if (f == 0) continue;
      for (var k = c; k < 9; k++) {
        a[r][k] -= f * a[c][k];
      }
    }
  }
  return [for (var r = 0; r < 8; r++) a[r][8], 1];
}

/// Paper and ink levels of a page (luminance 0 … 255): the 3rd and 85th
/// percentiles, used to make the paper white without crushing the text.
(double, double) pageLevels(Uint8List rgba) {
  final hist = List<int>.filled(256, 0);
  var n = 0;
  for (var i = 0; i < rgba.length; i += 4 * 7) {
    hist[(0.299 * rgba[i] + 0.587 * rgba[i + 1] + 0.114 * rgba[i + 2]).round()]++;
    n++;
  }
  int pct(double p) {
    var acc = 0;
    for (var t = 0; t < 256; t++) {
      acc += hist[t];
      if (acc >= n * p) return t;
    }
    return 255;
  }

  final lo = pct(0.03).toDouble(), hi = pct(0.85).toDouble();
  return (lo, math.max(lo + 40, hi));
}
