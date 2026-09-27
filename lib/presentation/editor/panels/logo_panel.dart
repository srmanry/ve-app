import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../../../domain/entities/sticker_layer.dart';
import '../../widgets/logo_picker.dart';
import '../state/editor_controller.dart';
import 'panel_common.dart';

/// Logo / watermark: add a saved logo over the whole video, snap it to a
/// corner (or drag it anywhere in the preview), resize, fade.
class LogoPanel extends ConsumerWidget {
  const LogoPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(editorProvider.notifier);
    final selected = ref.watch(editorProvider.select((s) => s.selectedSticker));
    final logo = selected != null && selected.sticker.isImage ? selected : null;

    return ToolPanel(
      title: 'Logo',
      onClose: () => controller.openTool(null),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            logo == null
                ? 'Pick a logo to place it on the whole video.'
                : 'Drag the logo in the preview, or snap it to a corner.',
            style: TextStyle(fontSize: 12, color: context.mutedColor),
          ),
          const SizedBox(height: 8),
          LogoPicker(
            selected: logo?.sticker.value as String?,
            onSelected: (path) {
              if (logo == null) {
                controller.addLogo(path);
              } else {
                controller.updateSticker(
                  logo.id,
                  (s) => s.copyWith(sticker: StickerSpec.image(path)),
                );
              }
            },
          ),
          if (logo != null) _LogoEditor(layer: logo),
        ],
      ),
    );
  }
}

class _LogoEditor extends ConsumerWidget {
  const _LogoEditor({required this.layer});
  final StickerLayer layer;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = ref.read(editorProvider.notifier);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 10),
        LogoPositionChips(onSelected: (p) => c.placeLogo(layer.id, p)),
        LabeledSlider(
          label: 'Size',
          value: layer.transform.scale,
          min: 0.2,
          max: 4,
          format: (v) => '${(v * 100).round()}%',
          onChangeStart: (_) => c.beginChange(),
          onChanged: (v) => c.updateSticker(
            layer.id,
            (s) => s.copyWith(transform: s.transform.copyWith(scale: v)),
            live: true,
          ),
        ),
        LabeledSlider(
          label: 'Opacity',
          value: layer.opacity,
          min: 0.1,
          max: 1,
          format: (v) => '${(v * 100).round()}%',
          onChangeStart: (_) => c.beginChange(),
          onChanged: (v) => c.updateSticker(layer.id, (s) => s.copyWith(opacity: v), live: true),
        ),
        Row(
          children: [
            TextButton.icon(
              icon: const Icon(Icons.width_full_outlined),
              label: const Text('Show for whole video'),
              onPressed: () => c.stretchStickerToVideo(layer.id),
            ),
            const Spacer(),
            TextButton.icon(
              style: TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
              icon: const Icon(Icons.delete_outline),
              label: const Text('Remove'),
              onPressed: c.deleteSelection,
            ),
          ],
        ),
      ],
    );
  }
}
