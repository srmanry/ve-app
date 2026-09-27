import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../../../domain/entities/video_clip.dart';

/// Crop aspect presets (section 7). `null` ratio = free crop.
enum CropAspect {
  free('Free', null),
  r16x9('16:9', 16 / 9),
  r9x16('9:16', 9 / 16),
  r1x1('1:1', 1),
  r4x5('4:5', 4 / 5),
  r4x3('4:3', 4 / 3);

  const CropAspect(this.label, this.ratio);
  final String label;
  final double? ratio;

  /// Largest centred crop with this pixel aspect for a frame of
  /// [frameAspect] (w/h).
  CropRect initialRect(double frameAspect) {
    final r = ratio;
    if (r == null) return CropRect.full;
    if (r > frameAspect) {
      final h = frameAspect / r;
      return CropRect(0, (1 - h) / 2, 1, h);
    }
    final w = r / frameAspect;
    return CropRect((1 - w) / 2, 0, w, 1);
  }
}

/// Interactive crop rectangle drawn over the uncropped frame.
///
/// Drag inside to move, drag corners to resize. With a fixed [aspect] the
/// pixel aspect ratio is preserved while resizing.
class CropOverlay extends StatefulWidget {
  const CropOverlay({
    super.key,
    required this.frameAspect,
    required this.crop,
    required this.aspect,
    required this.onChangeStart,
    required this.onChanged,
  });

  /// Displayed frame aspect ratio (w/h).
  final double frameAspect;
  final CropRect crop;
  final CropAspect aspect;
  final VoidCallback onChangeStart;
  final ValueChanged<CropRect> onChanged;

  @override
  State<CropOverlay> createState() => _CropOverlayState();
}

enum _Handle { move, topLeft, topRight, bottomLeft, bottomRight }

class _CropOverlayState extends State<CropOverlay> {
  static const _minSize = 0.1;
  _Handle? _active;
  late CropRect _startRect;
  late Offset _startPoint;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        // The frame is letterboxed (BoxFit.contain) inside the preview.
        final boxAspect = box.maxWidth / box.maxHeight;
        final Size frame = widget.frameAspect > boxAspect
            ? Size(box.maxWidth, box.maxWidth / widget.frameAspect)
            : Size(box.maxHeight * widget.frameAspect, box.maxHeight);
        final origin = Offset((box.maxWidth - frame.width) / 2, (box.maxHeight - frame.height) / 2);
        final c = widget.crop;
        final rect = Rect.fromLTWH(
          origin.dx + c.left * frame.width,
          origin.dy + c.top * frame.height,
          c.width * frame.width,
          c.height * frame.height,
        );

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: (d) {
            _active = _hitHandle(d.localPosition, rect);
            if (_active == null) return;
            widget.onChangeStart();
            _startRect = widget.crop;
            _startPoint = d.localPosition;
          },
          onPanUpdate: (d) {
            if (_active == null) return;
            final delta = d.localPosition - _startPoint;
            widget.onChanged(_update(_startRect, delta.dx / frame.width, delta.dy / frame.height));
          },
          onPanEnd: (_) => _active = null,
          child: CustomPaint(size: Size(box.maxWidth, box.maxHeight), painter: _CropPainter(rect)),
        );
      },
    );
  }

  _Handle? _hitHandle(Offset p, Rect rect) {
    const r = 28.0;
    if ((p - rect.topLeft).distance < r) return _Handle.topLeft;
    if ((p - rect.topRight).distance < r) return _Handle.topRight;
    if ((p - rect.bottomLeft).distance < r) return _Handle.bottomLeft;
    if ((p - rect.bottomRight).distance < r) return _Handle.bottomRight;
    if (rect.inflate(8).contains(p)) return _Handle.move;
    return null;
  }

  CropRect _update(CropRect s, double dx, double dy) {
    if (_active == _Handle.move) {
      return CropRect(
        (s.left + dx).clamp(0.0, 1 - s.width),
        (s.top + dy).clamp(0.0, 1 - s.height),
        s.width,
        s.height,
      );
    }
    var left = s.left, top = s.top, right = s.left + s.width, bottom = s.top + s.height;
    switch (_active!) {
      case _Handle.topLeft:
        left += dx;
        top += dy;
      case _Handle.topRight:
        right += dx;
        top += dy;
      case _Handle.bottomLeft:
        left += dx;
        bottom += dy;
      case _Handle.bottomRight:
        right += dx;
        bottom += dy;
      case _Handle.move:
        break;
    }
    left = left.clamp(0.0, right - _minSize);
    top = top.clamp(0.0, bottom - _minSize);
    right = right.clamp(left + _minSize, 1.0);
    bottom = bottom.clamp(top + _minSize, 1.0);

    final ratio = widget.aspect.ratio;
    if (ratio != null) {
      // Keep pixel aspect: (w * frameAspect) / h == ratio. Adjust height to
      // match width, anchored at the edge opposite the dragged corner.
      var w = right - left;
      var h = w * widget.frameAspect / ratio;
      final anchorTop = _active == _Handle.bottomLeft || _active == _Handle.bottomRight;
      final maxH = anchorTop ? 1 - top : bottom;
      if (h > maxH) {
        h = maxH;
        w = h * ratio / widget.frameAspect;
        final anchorLeft = _active == _Handle.topRight || _active == _Handle.bottomRight;
        if (anchorLeft) {
          right = left + w;
        } else {
          left = right - w;
        }
      }
      if (anchorTop) {
        bottom = top + h;
      } else {
        top = bottom - h;
      }
    }
    return CropRect(left, top, right - left, bottom - top);
  }
}

class _CropPainter extends CustomPainter {
  _CropPainter(this.rect);
  final Rect rect;

  @override
  void paint(Canvas canvas, Size size) {
    final shade = Paint()..color = const Color(0x99000000);
    final outer = Path()..addRect(Offset.zero & size);
    final hole = Path()..addRect(rect);
    canvas.drawPath(Path.combine(PathOperation.difference, outer, hole), shade);

    final border = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    canvas.drawRect(rect, border);

    // Rule-of-thirds guides.
    final guide = Paint()
      ..color = Colors.white38
      ..strokeWidth = 0.8;
    for (var i = 1; i < 3; i++) {
      final x = rect.left + rect.width * i / 3;
      final y = rect.top + rect.height * i / 3;
      canvas.drawLine(Offset(x, rect.top), Offset(x, rect.bottom), guide);
      canvas.drawLine(Offset(rect.left, y), Offset(rect.right, y), guide);
    }

    final handle = Paint()
      ..color = AppColors.selection
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round;
    const l = 16.0;
    for (final (corner, sx, sy) in [
      (rect.topLeft, 1.0, 1.0),
      (rect.topRight, -1.0, 1.0),
      (rect.bottomLeft, 1.0, -1.0),
      (rect.bottomRight, -1.0, -1.0),
    ]) {
      canvas.drawLine(corner, corner + Offset(l * sx, 0), handle);
      canvas.drawLine(corner, corner + Offset(0, l * sy), handle);
    }
  }

  @override
  bool shouldRepaint(_CropPainter old) => old.rect != rect;
}
