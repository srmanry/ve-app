import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../../domain/entities/video_effect.dart';

/// Live approximation of a clip [VideoEffect] on the preview canvas.
///
/// Strengths are expressed relative to the canvas, like the FFmpeg filters in
/// `FfmpegCommandBuilder._effectFilter`, so preview and export match in
/// scale. Invert is handled by the colour matrix; sharpen has no preview.
class EffectPreview extends StatelessWidget {
  const EffectPreview({
    super.key,
    required this.effect,
    required this.intensity,
    required this.outputWidth,
    required this.time,
    required this.child,
  });

  final VideoEffect effect;
  final double intensity;

  /// Export frame width, used to match pixelation block counts.
  final int outputWidth;

  /// Timeline position; animates film grain.
  final Duration time;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final k = intensity.clamp(0.0, 1.0);
    if (k <= 0) return child;
    return LayoutBuilder(
      builder: (context, box) {
        final w = box.maxWidth, h = box.maxHeight;
        switch (effect) {
          case VideoEffect.none:
          case VideoEffect.invert:
          case VideoEffect.sharpen:
            return child;
          case VideoEffect.blur:
            final sigma = math.max(0.5, k * 0.03 * math.min(w, h));
            return ClipRect(
              child: ImageFiltered(
                imageFilter: ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
                child: child,
              ),
            );
          case VideoEffect.vignette:
            return Stack(
              fit: StackFit.expand,
              children: [
                child,
                IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: RadialGradient(
                        radius: 0.95 - 0.3 * k,
                        colors: [
                          Colors.transparent,
                          Colors.black.withValues(alpha: 0.5 + 0.5 * k),
                        ],
                        stops: const [0.45, 1.0],
                      ),
                    ),
                  ),
                ),
              ],
            );
          case VideoEffect.mirror:
            Widget leftHalf() => ClipRect(
              child: Align(
                alignment: Alignment.centerLeft,
                widthFactor: 0.5,
                child: SizedBox(width: w, height: h, child: child),
              ),
            );
            return Row(
              children: [
                leftHalf(),
                Transform.flip(flipX: true, child: leftHalf()),
              ],
            );
          case VideoEffect.glitch:
            final shift = math.max(1.0, k * 0.012 * w);
            Widget channel(List<double> m, double dx) => Transform.translate(
              offset: Offset(dx, 0),
              child: Opacity(
                opacity: 0.55,
                child: ColorFiltered(colorFilter: ColorFilter.matrix(m), child: child),
              ),
            );
            return ClipRect(
              child: Stack(
                fit: StackFit.expand,
                children: [child, channel(_redOnly, -shift), channel(_blueOnly, shift)],
              ),
            );
          case VideoEffect.grain:
            return Stack(
              fit: StackFit.expand,
              children: [
                child,
                IgnorePointer(
                  child: CustomPaint(
                    painter: _GrainPainter(
                      strength: k,
                      // New pattern roughly every frame.
                      seed: time.inMilliseconds ~/ 40,
                    ),
                  ),
                ),
              ],
            );
          case VideoEffect.pixelate:
            // Same number of blocks across as the export.
            final block = 4 + (k * 28).round();
            final blocksAcross = math.max(2, (outputWidth / block).round());
            final dpr = MediaQuery.devicePixelRatioOf(context);
            final smallW = blocksAcross / dpr;
            final smallH = smallW * h / w;
            return ClipRect(
              child: OverflowBox(
                alignment: Alignment.topLeft,
                minWidth: 0,
                minHeight: 0,
                maxWidth: double.infinity,
                maxHeight: double.infinity,
                child: Transform.scale(
                  scale: w / smallW,
                  alignment: Alignment.topLeft,
                  filterQuality: FilterQuality.none,
                  child: SizedBox(
                    width: smallW,
                    height: smallH,
                    child: FittedBox(
                      fit: BoxFit.fill,
                      child: SizedBox(width: w, height: h, child: child),
                    ),
                  ),
                ),
              ),
            );
        }
      },
    );
  }

  static const _redOnly = <double>[
    1, 0, 0, 0, 0, //
    0, 0, 0, 0, 0, //
    0, 0, 0, 0, 0, //
    0, 0, 0, 1, 0, //
  ];
  static const _blueOnly = <double>[
    0, 0, 0, 0, 0, //
    0, 0, 0, 0, 0, //
    0, 0, 1, 0, 0, //
    0, 0, 0, 1, 0, //
  ];
}

class _GrainPainter extends CustomPainter {
  _GrainPainter({required this.strength, required this.seed});
  final double strength;
  final int seed;

  @override
  void paint(Canvas canvas, Size size) {
    final random = math.Random(seed);
    final count = (size.width * size.height / 30 * strength).round().clamp(0, 12000);
    final light = <Offset>[], dark = <Offset>[];
    for (var i = 0; i < count; i++) {
      final p = Offset(random.nextDouble() * size.width, random.nextDouble() * size.height);
      (random.nextBool() ? light : dark).add(p);
    }
    final paint = Paint()
      ..strokeWidth = 1.2
      ..strokeCap = StrokeCap.round;
    canvas.drawPoints(
      ui.PointMode.points,
      light,
      paint..color = Colors.white.withValues(alpha: 0.35 * strength),
    );
    canvas.drawPoints(
      ui.PointMode.points,
      dark,
      paint..color = Colors.black.withValues(alpha: 0.35 * strength),
    );
  }

  @override
  bool shouldRepaint(_GrainPainter old) => old.seed != seed || old.strength != strength;
}
