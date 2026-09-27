import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/utils/formatters.dart';
import '../../../domain/entities/audio_track.dart';
import '../../../domain/entities/pip_layer.dart';
import '../../../domain/entities/sticker_layer.dart';
import '../../../domain/entities/text_layer.dart';
import '../../widgets/app_dialogs.dart';
import '../../widgets/media_import_flow.dart';
import '../editor_scope.dart';
import '../preview/layer_painters.dart';
import '../state/editor_controller.dart';
import '../state/editor_state.dart';
import 'logo_panel.dart';
import 'panel_common.dart';

String _deg(double radians) => '${(radians * 180 / math.pi).round()}°';

Widget _deleteButton(BuildContext context, WidgetRef ref, String label) => Align(
  alignment: Alignment.centerLeft,
  child: TextButton.icon(
    style: TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
    icon: const Icon(Icons.delete_outline),
    label: Text(label),
    onPressed: () => ref.read(editorProvider.notifier).deleteSelection(),
  ),
);

/// Source trim for audio/PIP layers (in-point and out-point of the file).
Widget _sourceTrim({
  required String label,
  required Duration trimStart,
  required Duration trimEnd,
  required Duration sourceLength,
  required VoidCallback onStart,
  required void Function(Duration s, Duration e) onChanged,
}) {
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        '$label  ${Formatters.duration(trimStart, showTenths: true)} – '
        '${Formatters.duration(trimEnd, showTenths: true)}  '
        '(${Formatters.duration(trimEnd - trimStart, showTenths: true)})',
        style: const TextStyle(fontSize: 12),
      ),
      RangeSlider(
        values: RangeValues(
          trimStart.inMilliseconds.toDouble(),
          trimEnd.inMilliseconds.toDouble().clamp(0, sourceLength.inMilliseconds.toDouble()),
        ),
        min: 0,
        max: sourceLength.inMilliseconds.toDouble(),
        onChangeStart: (_) => onStart(),
        onChanged: (v) {
          if (v.end - v.start < 200) return;
          onChanged(Duration(milliseconds: v.start.round()), Duration(milliseconds: v.end.round()));
        },
      ),
    ],
  );
}

// --------------------------------------------------------------------- audio

class AudioPanel extends ConsumerWidget {
  const AudioPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(editorProvider.notifier);
    final tracks = ref.watch(editorProvider.select((s) => s.project.audioTracks));
    final selected = ref.watch(editorProvider.select((s) => s.selectedAudio));
    final playback = EditorScope.playbackOf(context);

    Future<void> addMusic() async {
      final media = await importAudio(context, ref);
      if (media.isNotEmpty) controller.addAudio(media.first, playback.position.value);
    }

    return ToolPanel(
      title: selected == null ? 'Audio' : 'Audio · ${selected.name}',
      onClose: () => controller.openTool(null),
      child: selected == null
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Wrap(
                  alignment: WrapAlignment.center,
                  children: [
                    PanelAction(
                      icon: Icons.library_music_outlined,
                      label: 'Add music',
                      onTap: addMusic,
                    ),
                    PanelAction(
                      icon: Icons.call_split,
                      label: 'From clip',
                      onTap: () async {
                        final state = ref.read(editorProvider);
                        final clip =
                            state.selectedClip ??
                            state.timeline.locate(playback.position.value)?.clip;
                        if (clip == null) return;
                        try {
                          await controller.detachAudio(clip.id);
                        } catch (e) {
                          if (context.mounted) await showAppError(context, e);
                        }
                      },
                    ),
                  ],
                ),
                for (final t in tracks)
                  ListTile(
                    dense: true,
                    leading: const Icon(Icons.music_note, color: AppColors.audioTrack),
                    title: Text(t.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text(
                      '${Formatters.duration(t.start)} · ${Formatters.duration(t.duration)}',
                    ),
                    onTap: () => controller.select(EditorSelection(SelectionKind.audio, t.id)),
                  ),
                if (tracks.isEmpty) const PanelHint('Supports MP3, M4A, WAV and AAC files.'),
              ],
            )
          : _AudioTrackEditor(track: selected),
    );
  }
}

class _AudioTrackEditor extends ConsumerWidget {
  const _AudioTrackEditor({required this.track});
  final AudioTrack track;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = ref.read(editorProvider.notifier);
    return Column(
      children: [
        LabeledSlider(
          label: 'Volume',
          value: track.volume,
          min: 0,
          max: 2,
          format: (v) => '${(v * 100).round()}%',
          onChangeStart: (_) => c.beginChange(),
          onChanged: (v) => c.updateAudio(track.id, (a) => a.copyWith(volume: v), live: true),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Mute'),
          value: track.muted,
          onChanged: (v) => c.updateAudio(track.id, (a) => a.copyWith(muted: v)),
        ),
        _sourceTrim(
          label: 'Trim',
          trimStart: track.trimStart,
          trimEnd: track.trimEnd,
          sourceLength: track.media.duration,
          onStart: c.beginChange,
          onChanged: (s, e) =>
              c.updateAudio(track.id, (a) => a.copyWith(trimStart: s, trimEnd: e), live: true),
        ),
        Row(
          children: [
            TextButton.icon(
              icon: const Icon(Icons.vertical_align_center),
              label: const Text('Move to playhead'),
              onPressed: () => c.updateAudio(
                track.id,
                (a) => a.copyWith(start: EditorScope.playbackOf(context).position.value),
              ),
            ),
            const Spacer(),
            _deleteButton(context, ref, 'Delete'),
          ],
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------- text

class TextPanel extends ConsumerWidget {
  const TextPanel({super.key});

  static Future<void> addText(BuildContext context, WidgetRef ref) async {
    final text = await promptText(
      context,
      title: 'Add text',
      hint: 'Type something',
      action: 'Add',
      maxLines: 3,
    );
    if (text == null || text.trim().isEmpty || !context.mounted) return;
    ref
        .read(editorProvider.notifier)
        .addText(text.trim(), EditorScope.playbackOf(context).position.value);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(editorProvider.notifier);
    final selected = ref.watch(editorProvider.select((s) => s.selectedText));
    return ToolPanel(
      title: 'Text',
      onClose: () => controller.openTool(null),
      actions: [
        if (selected != null)
          IconButton(
            tooltip: 'Add another',
            onPressed: () => addText(context, ref),
            icon: const Icon(Icons.add),
          ),
      ],
      child: selected == null
          ? PanelHint(
              'Add a text layer, then drag it in the preview. Pinch to resize and twist to rotate.',
              action: FilledButton.icon(
                onPressed: () => addText(context, ref),
                icon: const Icon(Icons.title),
                label: const Text('Add text'),
              ),
            )
          : _TextEditor(layer: selected),
    );
  }
}

class _TextEditor extends ConsumerWidget {
  const _TextEditor({required this.layer});
  final TextLayer layer;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = ref.read(editorProvider.notifier);
    final s = layer.style;
    void style(TextLayerStyle Function(TextLayerStyle s) change, {bool live = false}) =>
        c.updateText(layer.id, (t) => t.copyWith(style: change(t.style)), live: live);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                icon: const Icon(Icons.edit_outlined, size: 18),
                label: Text(layer.text, maxLines: 1, overflow: TextOverflow.ellipsis),
                onPressed: () async {
                  final text = await promptText(
                    context,
                    title: 'Edit text',
                    initial: layer.text,
                    maxLines: 3,
                  );
                  if (text != null && text.trim().isNotEmpty) {
                    c.updateText(layer.id, (t) => t.copyWith(text: text.trim()));
                  }
                },
              ),
            ),
            const SizedBox(width: 8),
            _toggle(
              context,
              Icons.format_bold,
              s.bold,
              () => style((x) => x.copyWith(bold: !x.bold)),
            ),
            _toggle(
              context,
              Icons.format_italic,
              s.italic,
              () => style((x) => x.copyWith(italic: !x.italic)),
            ),
          ],
        ),
        const SizedBox(height: 10),
        ChipRow<FontOption>(
          values: FontOption.all,
          selected: FontOption.all.where((f) => f.family == s.fontFamily).firstOrNull,
          label: (f) => f.label,
          onSelected: (f) => style((x) => x.copyWith(fontFamily: f.family)),
        ),
        const SizedBox(height: 10),
        SegmentedButton<TextAlignOption>(
          segments: const [
            ButtonSegment(value: TextAlignOption.left, icon: Icon(Icons.format_align_left)),
            ButtonSegment(value: TextAlignOption.center, icon: Icon(Icons.format_align_center)),
            ButtonSegment(value: TextAlignOption.right, icon: Icon(Icons.format_align_right)),
          ],
          selected: {s.align},
          onSelectionChanged: (v) => style((x) => x.copyWith(align: v.first)),
        ),
        const SizedBox(height: 10),
        const Text('Color', style: TextStyle(fontSize: 12)),
        const SizedBox(height: 4),
        ColorSwatchRow(
          selected: s.color,
          onSelected: (v) => style((x) => x.copyWith(color: v)),
        ),
        const SizedBox(height: 10),
        const Text('Background', style: TextStyle(fontSize: 12)),
        const SizedBox(height: 4),
        ColorSwatchRow(
          allowNone: true,
          selected: s.backgroundColor,
          onSelected: (v) => style((x) => x.copyWith(backgroundColor: v)),
        ),
        const SizedBox(height: 10),
        const Text('Border', style: TextStyle(fontSize: 12)),
        const SizedBox(height: 4),
        ColorSwatchRow(
          selected: s.strokeWidth > 0 ? s.strokeColor : null,
          allowNone: true,
          onSelected: (v) => style(
            (x) => v == null
                ? x.copyWith(strokeWidth: 0)
                : x.copyWith(strokeColor: v, strokeWidth: x.strokeWidth > 0 ? x.strokeWidth : 0.08),
          ),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Shadow'),
          value: s.shadow,
          onChanged: (v) => style((x) => x.copyWith(shadow: v)),
        ),
        LabeledSlider(
          label: 'Size',
          value: s.fontSize,
          min: 0.02,
          max: 0.2,
          format: (v) => (v * 1000).round().toString(),
          onChangeStart: (_) => c.beginChange(),
          onChanged: (v) => style((x) => x.copyWith(fontSize: v), live: true),
        ),
        if (s.strokeWidth > 0)
          LabeledSlider(
            label: 'Border width',
            value: s.strokeWidth,
            min: 0.02,
            max: 0.25,
            format: (v) => (v * 100).round().toString(),
            onChangeStart: (_) => c.beginChange(),
            onChanged: (v) => style((x) => x.copyWith(strokeWidth: v), live: true),
          ),
        LabeledSlider(
          label: 'Opacity',
          value: s.opacity,
          min: 0.1,
          max: 1,
          format: (v) => '${(v * 100).round()}%',
          onChangeStart: (_) => c.beginChange(),
          onChanged: (v) => style((x) => x.copyWith(opacity: v), live: true),
        ),
        LabeledSlider(
          label: 'Scale',
          value: layer.transform.scale,
          min: 0.2,
          max: 6,
          format: (v) => '${v.toStringAsFixed(1)}x',
          onChangeStart: (_) => c.beginChange(),
          onChanged: (v) => c.updateText(
            layer.id,
            (t) => t.copyWith(transform: t.transform.copyWith(scale: v)),
            live: true,
          ),
        ),
        LabeledSlider(
          label: 'Rotation',
          value: layer.transform.rotation,
          min: -math.pi,
          max: math.pi,
          format: _deg,
          onChangeStart: (_) => c.beginChange(),
          onChanged: (v) => c.updateText(
            layer.id,
            (t) => t.copyWith(transform: t.transform.copyWith(rotation: v)),
            live: true,
          ),
        ),
        _deleteButton(context, ref, 'Delete text'),
      ],
    );
  }

  Widget _toggle(BuildContext context, IconData icon, bool on, VoidCallback onTap) => IconButton(
    onPressed: onTap,
    icon: Icon(icon),
    style: IconButton.styleFrom(
      backgroundColor: on ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.25) : null,
    ),
  );
}

// ------------------------------------------------------------------- sticker

class StickerPanel extends ConsumerWidget {
  const StickerPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(editorProvider.notifier);
    final selected = ref.watch(editorProvider.select((s) => s.selectedSticker));
    // Logos are stickers too, but have their own controls.
    if (selected != null && selected.sticker.isImage) return const LogoPanel();
    return ToolPanel(
      title: 'Stickers',
      onClose: () => controller.openTool(null),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (selected != null) ...[
            _StickerEditor(layer: selected),
            const Divider(height: 20),
            const Text('Add another', style: TextStyle(fontSize: 12)),
            const SizedBox(height: 6),
          ],
          _StickerGrid(
            onPick: (spec) =>
                controller.addSticker(spec, EditorScope.playbackOf(context).position.value),
          ),
        ],
      ),
    );
  }
}

class _StickerGrid extends StatelessWidget {
  const _StickerGrid({required this.onPick});
  final ValueChanged<StickerSpec> onPick;

  @override
  Widget build(BuildContext context) {
    final specs = [
      for (final e in StickerSpec.emojis) StickerSpec.emoji(e),
      for (final s in StickerSpec.shapes) StickerSpec.shape(s),
    ];
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 52,
        mainAxisSpacing: 6,
        crossAxisSpacing: 6,
      ),
      itemCount: specs.length,
      itemBuilder: (context, i) => InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => onPick(specs[i]),
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: CustomPaint(painter: StickerSpecPainter(specs[i])),
        ),
      ),
    );
  }
}

class _StickerEditor extends ConsumerWidget {
  const _StickerEditor({required this.layer});
  final StickerLayer layer;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = ref.read(editorProvider.notifier);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (layer.sticker.kind == StickerKind.shape) ...[
          const Text('Color', style: TextStyle(fontSize: 12)),
          const SizedBox(height: 4),
          ColorSwatchRow(
            selected: layer.sticker.color,
            onSelected: (v) {
              if (v != null) {
                c.updateSticker(layer.id, (s) => s.copyWith(sticker: s.sticker.withColor(v)));
              }
            },
          ),
        ],
        LabeledSlider(
          label: 'Size',
          value: layer.transform.scale,
          min: 0.2,
          max: 6,
          format: (v) => '${v.toStringAsFixed(1)}x',
          onChangeStart: (_) => c.beginChange(),
          onChanged: (v) => c.updateSticker(
            layer.id,
            (s) => s.copyWith(transform: s.transform.copyWith(scale: v)),
            live: true,
          ),
        ),
        LabeledSlider(
          label: 'Rotation',
          value: layer.transform.rotation,
          min: -math.pi,
          max: math.pi,
          format: _deg,
          onChangeStart: (_) => c.beginChange(),
          onChanged: (v) => c.updateSticker(
            layer.id,
            (s) => s.copyWith(transform: s.transform.copyWith(rotation: v)),
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
        _deleteButton(context, ref, 'Delete sticker'),
      ],
    );
  }
}

// ----------------------------------------------------------------------- PIP

class PipPanel extends ConsumerWidget {
  const PipPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(editorProvider.notifier);
    final selected = ref.watch(editorProvider.select((s) => s.selectedPip));

    Future<void> addPip() async {
      final media = await importVideos(context, ref, multiple: false);
      if (media.isNotEmpty && context.mounted) {
        controller.addPip(media.first, EditorScope.playbackOf(context).position.value);
      }
    }

    return ToolPanel(
      title: 'Picture-in-picture',
      onClose: () => controller.openTool(null),
      actions: [
        if (selected != null)
          IconButton(tooltip: 'Add another', onPressed: addPip, icon: const Icon(Icons.add)),
      ],
      child: selected == null
          ? PanelHint(
              'Overlay a second video on top of the main video.',
              action: FilledButton.icon(
                onPressed: addPip,
                icon: const Icon(Icons.picture_in_picture_alt),
                label: const Text('Add overlay video'),
              ),
            )
          : _PipEditor(layer: selected),
    );
  }
}

class _PipEditor extends ConsumerWidget {
  const _PipEditor({required this.layer});
  final PipLayer layer;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = ref.read(editorProvider.notifier);
    void transform(double? scale, double? rotation) => c.updatePip(
      layer.id,
      (l) => l.copyWith(
        transform: l.transform.copyWith(scale: scale, rotation: rotation),
      ),
      live: true,
    );
    return Column(
      children: [
        const Text(
          'Drag the overlay in the preview to position it.',
          style: TextStyle(fontSize: 12, color: Colors.white60),
        ),
        LabeledSlider(
          label: 'Size',
          value: layer.transform.scale,
          min: 0.1,
          max: 1,
          format: (v) => '${(v * 100).round()}%',
          onChangeStart: (_) => c.beginChange(),
          onChanged: (v) => transform(v, null),
        ),
        LabeledSlider(
          label: 'Rotation',
          value: layer.transform.rotation,
          min: -math.pi,
          max: math.pi,
          format: _deg,
          onChangeStart: (_) => c.beginChange(),
          onChanged: (v) => transform(null, v),
        ),
        if (layer.media.hasAudio) ...[
          LabeledSlider(
            label: 'Volume',
            value: layer.volume,
            min: 0,
            max: 2,
            format: (v) => '${(v * 100).round()}%',
            onChangeStart: (_) => c.beginChange(),
            onChanged: (v) => c.updatePip(layer.id, (l) => l.copyWith(volume: v), live: true),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Mute overlay audio'),
            value: layer.muted,
            onChanged: (v) => c.updatePip(layer.id, (l) => l.copyWith(muted: v)),
          ),
        ],
        _sourceTrim(
          label: 'Trim',
          trimStart: layer.trimStart,
          trimEnd: layer.trimEnd,
          sourceLength: layer.media.duration,
          onStart: c.beginChange,
          onChanged: (s, e) =>
              c.updatePip(layer.id, (l) => l.copyWith(trimStart: s, trimEnd: e), live: true),
        ),
        Text(
          'On timeline: ${Formatters.duration(layer.start, showTenths: true)} – '
          '${Formatters.duration(layer.start + layer.duration, showTenths: true)}',
          style: const TextStyle(fontSize: 12),
        ),
        _deleteButton(context, ref, 'Delete overlay'),
      ],
    );
  }
}
