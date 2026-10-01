import 'dart:math' as math;
import 'dart:typed_data';

/// Pixels plus the spots to heal, for running [healSpots] in an isolate.
class HealJob {
  const HealJob(this.rgba, this.width, this.height, this.spots);

  /// Straight RGBA, row-major.
  final Uint8List rgba;
  final int width;
  final int height;

  /// (centre x, centre y, radius) in pixels.
  final List<(double, double, double)> spots;
}

/// Removes blemishes like a spot-healing brush: each spot is covered with a
/// nearby patch whose surroundings match best, colour-corrected to the spot's
/// own surroundings and feathered in, so skin texture is kept.
///
/// Returns a new buffer; [HealJob.rgba] is not modified.
Uint8List healSpots(HealJob job) {
  final px = Uint8List.fromList(job.rgba);
  for (final (cx, cy, r) in job.spots) {
    _heal(px, job.width, job.height, cx, cy, math.max(2.0, r));
  }
  return px;
}

void _heal(Uint8List px, int w, int h, double cx, double cy, double r) {
  final outer = r * 1.5;
  final reach = outer.ceil();
  // Sample the ring around the spot sparsely: enough to compare, cheap.
  final step = math.max(1, (r / 6).floor());
  final ring = <(int, int)>[];
  for (var dy = -reach; dy <= reach; dy += step) {
    for (var dx = -reach; dx <= reach; dx += step) {
      final d = math.sqrt(dx * dx + dy * dy);
      if (d >= r && d <= outer) ring.add((dx, dy));
    }
  }
  final tx = cx.round(), ty = cy.round();
  if (ring.isEmpty) return;

  int at(int x, int y) => (y * w + x) * 4;
  bool inside(int x, int y) => x - reach >= 0 && y - reach >= 0 && x + reach < w && y + reach < h;

  // Mean of the target ring (pixels that exist).
  double mr = 0, mg = 0, mb = 0;
  var n = 0;
  for (final (dx, dy) in ring) {
    final x = tx + dx, y = ty + dy;
    if (x < 0 || y < 0 || x >= w || y >= h) continue;
    final i = at(x, y);
    mr += px[i];
    mg += px[i + 1];
    mb += px[i + 2];
    n++;
  }
  if (n == 0) return;
  mr /= n;
  mg /= n;
  mb /= n;

  // Best-matching source patch around the spot.
  int? bestX, bestY;
  var bestScore = double.infinity;
  for (var k = 0; k < 16; k++) {
    final a = k * math.pi / 8;
    for (final dist in [2.3 * r, 3.2 * r]) {
      final sx = (cx + math.cos(a) * dist).round();
      final sy = (cy + math.sin(a) * dist).round();
      if (!inside(sx, sy)) continue;
      double score = 0;
      for (final (dx, dy) in ring) {
        final x = tx + dx, y = ty + dy;
        if (x < 0 || y < 0 || x >= w || y >= h) continue;
        final i = at(x, y), j = at(sx + dx, sy + dy);
        final er = px[i] - px[j], eg = px[i + 1] - px[j + 1], eb = px[i + 2] - px[j + 2];
        score += er * er + eg * eg + eb * eb;
        if (score >= bestScore) break;
      }
      if (score < bestScore) {
        bestScore = score;
        bestX = sx;
        bestY = sy;
      }
    }
  }

  // Colour shift so the patch blends with the spot's surroundings.
  double sr = 0, sg = 0, sb = 0;
  if (bestX != null) {
    for (final (dx, dy) in ring) {
      final j = at(bestX + dx, bestY! + dy);
      sr += px[j];
      sg += px[j + 1];
      sb += px[j + 2];
    }
    sr = mr - sr / ring.length;
    sg = mg - sg / ring.length;
    sb = mb - sb / ring.length;
  }

  // Copy the source disk first so overlapping writes never feed back.
  final ri = r.ceil();
  final size = ri * 2 + 1;
  final patch = Uint8List(size * size * 3);
  if (bestX != null) {
    for (var dy = -ri; dy <= ri; dy++) {
      for (var dx = -ri; dx <= ri; dx++) {
        final j = at(bestX + dx, bestY! + dy);
        final k = ((dy + ri) * size + dx + ri) * 3;
        patch[k] = px[j];
        patch[k + 1] = px[j + 1];
        patch[k + 2] = px[j + 2];
      }
    }
  }

  // Feathered blend: fully replaced inside 60% of the radius.
  final core = r * 0.6;
  for (var dy = -ri; dy <= ri; dy++) {
    for (var dx = -ri; dx <= ri; dx++) {
      final x = tx + dx, y = ty + dy;
      if (x < 0 || y < 0 || x >= w || y >= h) continue;
      final d = math.sqrt(dx * dx + dy * dy);
      if (d > r) continue;
      var t = d <= core ? 1.0 : 1 - (d - core) / (r - core);
      t = t * t * (3 - 2 * t);
      final i = at(x, y);
      double nr, ng, nb;
      if (bestX != null) {
        final k = ((dy + ri) * size + dx + ri) * 3;
        nr = patch[k] + sr;
        ng = patch[k + 1] + sg;
        nb = patch[k + 2] + sb;
      } else {
        // Near the edge of the photo: fall back to the surrounding colour.
        nr = mr;
        ng = mg;
        nb = mb;
      }
      px[i] = (px[i] + (nr - px[i]) * t).round().clamp(0, 255);
      px[i + 1] = (px[i + 1] + (ng - px[i + 1]) * t).round().clamp(0, 255);
      px[i + 2] = (px[i + 2] + (nb - px[i + 2]) * t).round().clamp(0, 255);
    }
  }
}
