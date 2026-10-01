import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../domain/entities/image_edit.dart';

/// Crop frame with draggable corners (and drag inside to move).
class CropFrame extends StatefulWidget {
  const CropFrame({
    super.key,
    required this.crop,
    required this.ratio,
    required this.photoAspect,
    required this.onChanged,
    required this.child,
  });

  final CropRect crop;

  /// Locked pixel aspect (w/h), or null for free.
  final double? ratio;
  final double photoAspect;
  final ValueChanged<CropRect> onChanged;
  final Widget child;

  @override
  State<CropFrame> createState() => _CropFrameState();
}

enum _Drag { none, move, tl, tr, bl, br }

class _CropFrameState extends State<CropFrame> {
  _Drag _drag = _Drag.none;
  static const _min = 0.08;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final size = box.biggest;
      final c = widget.crop;
      final rect = Rect.fromLTRB(c.left * size.width, c.top * size.height, c.right * size.width, c.bottom * size.height);
      return GestureDetector(
        onPanStart: (d) => _drag = _hit(d.localPosition, rect),
        onPanUpdate: (d) => _update(d.localPosition, d.delta, size),
        onPanEnd: (_) => _drag = _Drag.none,
        child: Stack(
          children: [
            widget.child,
            Positioned.fill(child: CustomPaint(painter: _CropFramePainter(rect))),
          ],
        ),
      );
    },
  );

  _Drag _hit(Offset pos, Rect r) {
    const reach = 36.0;
    final corners = {
      _Drag.tl: r.topLeft,
      _Drag.tr: r.topRight,
      _Drag.bl: r.bottomLeft,
      _Drag.br: r.bottomRight,
    };
    for (final e in corners.entries) {
      if ((e.value - pos).distance <= reach) return e.key;
    }
    return r.contains(pos) ? _Drag.move : _Drag.none;
  }

  void _update(Offset pos, Offset delta, Size size) {
    final c = widget.crop;
    if (_drag == _Drag.none) return;
    if (_drag == _Drag.move) {
      var dx = delta.dx / size.width, dy = delta.dy / size.height;
      dx = dx.clamp(-c.left, 1 - c.right);
      dy = dy.clamp(-c.top, 1 - c.bottom);
      widget.onChanged(CropRect(c.left + dx, c.top + dy, c.right + dx, c.bottom + dy));
      return;
    }
    final x = (pos.dx / size.width).clamp(0.0, 1.0);
    final y = (pos.dy / size.height).clamp(0.0, 1.0);
    // The fixed corner opposite the one being dragged.
    final fx = (_drag == _Drag.tl || _drag == _Drag.bl) ? c.right : c.left;
    final fy = (_drag == _Drag.tl || _drag == _Drag.tr) ? c.bottom : c.top;
    var w = (x - fx).abs().clamp(_min, 1.0);
    var h = (y - fy).abs().clamp(_min, 1.0);
    final ratio = widget.ratio;
    if (ratio != null) {
      // Fraction-space ratio: pixel ratio adjusted for the photo's shape.
      final r = ratio / widget.photoAspect;
      if (w / h > r) {
        w = h * r;
      } else {
        h = w / r;
      }
      final maxW = (_drag == _Drag.tl || _drag == _Drag.bl) ? fx : 1 - fx;
      final maxH = (_drag == _Drag.tl || _drag == _Drag.tr) ? fy : 1 - fy;
      final k = math.min(1.0, math.min(maxW / w, maxH / h));
      w *= k;
      h *= k;
    }
    final left = (_drag == _Drag.tl || _drag == _Drag.bl) ? (fx - w).clamp(0.0, 1.0) : fx;
    final top = (_drag == _Drag.tl || _drag == _Drag.tr) ? (fy - h).clamp(0.0, 1.0) : fy;
    final right = (_drag == _Drag.tl || _drag == _Drag.bl) ? fx : (fx + w).clamp(0.0, 1.0);
    final bottom = (_drag == _Drag.tl || _drag == _Drag.tr) ? fy : (fy + h).clamp(0.0, 1.0);
    widget.onChanged(CropRect(left, top, right, bottom));
  }
}

class _CropFramePainter extends CustomPainter {
  _CropFramePainter(this.rect);
  final Rect rect;

  @override
  void paint(Canvas canvas, Size size) {
    final dim = Paint()..color = Colors.black.withValues(alpha: 0.55);
    canvas.drawPath(
      Path.combine(PathOperation.difference, Path()..addRect(Offset.zero & size), Path()..addRect(rect)),
      dim,
    );
    final line = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    canvas.drawRect(rect, line);
    final grid = Paint()
      ..color = Colors.white38
      ..strokeWidth = 0.8;
    for (var i = 1; i < 3; i++) {
      final x = rect.left + rect.width * i / 3;
      final y = rect.top + rect.height * i / 3;
      canvas.drawLine(Offset(x, rect.top), Offset(x, rect.bottom), grid);
      canvas.drawLine(Offset(rect.left, y), Offset(rect.right, y), grid);
    }
    final corner = Paint()
      ..color = Colors.white
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round;
    const l = 18.0;
    for (final (p, dx, dy) in [
      (rect.topLeft, 1.0, 1.0),
      (rect.topRight, -1.0, 1.0),
      (rect.bottomLeft, 1.0, -1.0),
      (rect.bottomRight, -1.0, -1.0),
    ]) {
      canvas.drawLine(p, p + Offset(l * dx, 0), corner);
      canvas.drawLine(p, p + Offset(0, l * dy), corner);
    }
  }

  @override
  bool shouldRepaint(_CropFramePainter old) => old.rect != rect;
}
