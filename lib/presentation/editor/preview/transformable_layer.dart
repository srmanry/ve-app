import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../../../domain/entities/layer_transform.dart';

/// Positions a layer on the preview canvas from its [LayerTransform] and
/// lets the user move (drag), resize (pinch) and rotate (twist) it.
///
/// Gestures use global coordinates so they are unaffected by the layer's
/// own rotation/scale.
class TransformableLayer extends StatefulWidget {
  const TransformableLayer({
    super.key,
    required this.canvasSize,
    required this.contentSize,
    required this.transform,
    required this.selected,
    required this.onSelect,
    required this.onGestureStart,
    required this.onTransform,
    required this.child,
    this.minScale = 0.2,
    this.maxScale = 6,
  });

  final Size canvasSize;

  /// Unscaled layer size in canvas pixels.
  final Size contentSize;
  final LayerTransform transform;
  final bool selected;
  final VoidCallback onSelect;
  final VoidCallback onGestureStart;
  final ValueChanged<LayerTransform> onTransform;
  final Widget child;
  final double minScale;
  final double maxScale;

  @override
  State<TransformableLayer> createState() => _TransformableLayerState();
}

class _TransformableLayerState extends State<TransformableLayer> {
  late LayerTransform _start;
  late Offset _startFocal;

  @override
  Widget build(BuildContext context) {
    final t = widget.transform;
    final size = widget.contentSize;
    final w = widget.canvasSize.width, h = widget.canvasSize.height;
    // Extra touch slop around small layers.
    const pad = 12.0;

    return Positioned(
      left: t.x * w - size.width / 2 - pad,
      top: t.y * h - size.height / 2 - pad,
      width: size.width + pad * 2,
      height: size.height + pad * 2,
      child: Transform.rotate(
        angle: t.rotation,
        child: Transform.scale(
          scale: t.scale,
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: widget.onSelect,
            onScaleStart: (d) {
              widget.onSelect();
              widget.onGestureStart();
              _start = widget.transform;
              _startFocal = d.focalPoint;
            },
            onScaleUpdate: (d) {
              final delta = d.focalPoint - _startFocal;
              widget.onTransform(
                _start.copyWith(
                  x: (_start.x + delta.dx / w).clamp(0.0, 1.0),
                  y: (_start.y + delta.dy / h).clamp(0.0, 1.0),
                  scale: (_start.scale * d.scale).clamp(widget.minScale, widget.maxScale),
                  rotation: _normalize(_start.rotation + d.rotation),
                ),
              );
            },
            child: Padding(
              padding: const EdgeInsets.all(pad),
              child: DecoratedBox(
                position: DecorationPosition.foreground,
                decoration: BoxDecoration(
                  border: widget.selected
                      ? Border.all(color: AppColors.selection, width: 1.5 / t.scale.clamp(0.2, 10))
                      : null,
                ),
                child: widget.child,
              ),
            ),
          ),
        ),
      ),
    );
  }

  static double _normalize(double a) {
    var r = a % (2 * math.pi);
    if (r > math.pi) r -= 2 * math.pi;
    // Snap near-straight angles, which users usually intend.
    for (final snap in [0.0, math.pi / 2, -math.pi / 2, math.pi, -math.pi]) {
      if ((r - snap).abs() < 0.04) return snap;
    }
    return r;
  }
}
