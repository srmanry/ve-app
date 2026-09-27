import 'package:flutter/material.dart';

import '../../../core/utils/formatters.dart';

/// Time ruler. Tick spacing adapts to the zoom level and only the visible
/// range is painted.
class TimelineRuler extends StatelessWidget {
  const TimelineRuler({
    super.key,
    required this.height,
    required this.width,
    required this.pps,
    required this.visibleStart,
    required this.visibleEnd,
    required this.onSeek,
  });

  final double height;
  final double width;
  final double pps;
  final Duration visibleStart;
  final Duration visibleEnd;
  final ValueChanged<Duration> onSeek;

  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTapUp: (d) => onSeek(Duration(microseconds: (d.localPosition.dx / pps * 1e6).round())),
    child: CustomPaint(
      size: Size(width, height),
      painter: _RulerPainter(
        pps,
        visibleStart,
        visibleEnd,
        Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.55),
      ),
    ),
  );
}

class _RulerPainter extends CustomPainter {
  _RulerPainter(this.pps, this.start, this.end, this.color);

  final double pps;
  final Duration start;
  final Duration end;
  final Color color;

  static const _steps = [0.5, 1.0, 2.0, 5.0, 10.0, 15.0, 30.0, 60.0, 120.0, 300.0, 600.0];

  @override
  void paint(Canvas canvas, Size size) {
    final major = _steps.firstWhere((s) => s * pps >= 70, orElse: () => _steps.last);
    final minor = major / 5;
    final showMinor = minor * pps >= 8;
    final tick = Paint()
      ..color = color
      ..strokeWidth = 1;

    final startSec = start.inMilliseconds / 1000;
    final endSec = end.inMilliseconds / 1000;
    final step = showMinor ? minor : major;
    var t = (startSec / step).floor() * step;
    if (t < 0) t = 0;
    final maxSec = size.width / pps;

    while (t <= endSec && t <= maxSec + 1e-6) {
      final x = t * pps;
      final isMajor = ((t / major) - (t / major).round()).abs() < 1e-6;
      canvas.drawLine(Offset(x, size.height), Offset(x, size.height - (isMajor ? 8 : 4)), tick);
      if (isMajor) {
        final label = TextPainter(
          text: TextSpan(
            text: Formatters.duration(
              Duration(milliseconds: (t * 1000).round()),
              showTenths: major < 1,
            ),
            style: TextStyle(color: color, fontSize: 10),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        label.paint(canvas, Offset(x + 3, 1));
        label.dispose();
      }
      t += step;
    }
  }

  @override
  bool shouldRepaint(_RulerPainter old) =>
      old.pps != pps || old.start != start || old.end != end || old.color != color;
}
