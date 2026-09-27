import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../domain/entities/canvas_settings.dart';
import '../state/editor_controller.dart';
import 'panel_common.dart';

class CanvasPanel extends ConsumerWidget {
  const CanvasPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(editorProvider.notifier);
    final canvas = ref.watch(editorProvider.select((s) => s.project.canvas));
    return ToolPanel(
      title: 'Canvas',
      onClose: () => controller.openTool(null),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Aspect ratio', style: TextStyle(fontSize: 12)),
          const SizedBox(height: 6),
          ChipRow<AspectRatioPreset>(
            values: AspectRatioPreset.values,
            selected: canvas.aspectRatio,
            label: (a) => a.label,
            onSelected: (a) => controller.setCanvas(canvas.copyWith(aspectRatio: a)),
          ),
          const SizedBox(height: 12),
          SegmentedButton<CanvasFit>(
            segments: [
              for (final f in CanvasFit.values) ButtonSegment(value: f, label: Text(f.label)),
            ],
            selected: {canvas.fit},
            onSelectionChanged: (v) => controller.setCanvas(canvas.copyWith(fit: v.first)),
          ),
          if (canvas.fit == CanvasFit.fit) ...[
            const SizedBox(height: 12),
            const Text('Background', style: TextStyle(fontSize: 12)),
            const SizedBox(height: 6),
            ColorSwatchRow(
              selected: canvas.backgroundColor,
              onSelected: (c) {
                if (c != null) controller.setCanvas(canvas.copyWith(backgroundColor: c));
              },
            ),
          ],
        ],
      ),
    );
  }
}
