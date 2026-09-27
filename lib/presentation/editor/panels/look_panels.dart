import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../core/theme/app_theme.dart';
import '../../../domain/entities/color_adjustments.dart';
import '../../../domain/entities/transition.dart';
import '../../../domain/entities/video_clip.dart';
import '../../../services/video/color_matrix.dart';
import '../../widgets/app_dialogs.dart';
import '../state/editor_controller.dart';
import 'clip_panels.dart';
import 'panel_common.dart';

// -------------------------------------------------------------------- filter

class FilterPanel extends ClipPanel {
  const FilterPanel({super.key});

  @override
  String get title => 'Filters';

  @override
  Widget buildForClip(BuildContext context, WidgetRef ref, VideoClip clip, int index) {
    final controller = ref.read(editorProvider.notifier);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 92,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: FilterPreset.values.length,
            separatorBuilder: (_, _) => const SizedBox(width: 10),
            itemBuilder: (context, i) {
              final preset = FilterPreset.values[i];
              return _FilterSwatch(
                clip: clip,
                preset: preset,
                selected: clip.filter == preset,
                onTap: () => controller.setFilter(clip.id, preset),
              );
            },
          ),
        ),
        if (clip.filter != FilterPreset.original)
          LabeledSlider(
            label: 'Strength',
            value: clip.filterStrength,
            min: 0,
            max: 1,
            format: (v) => '${(v * 100).round()}%',
            onChangeStart: (_) => controller.beginChange(),
            onChanged: (v) => controller.setFilterStrength(clip.id, v, live: true),
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            icon: const Icon(Icons.done_all),
            label: const Text('Apply to all clips'),
            onPressed: () {
              controller.setFilter(clip.id, clip.filter, applyToAll: true);
              showSnack(context, '${clip.filter.label} applied to all clips.');
            },
          ),
        ),
      ],
    );
  }
}

class _FilterSwatch extends ConsumerWidget {
  const _FilterSwatch({
    required this.clip,
    required this.preset,
    required this.selected,
    required this.onTap,
  });

  final VideoClip clip;
  final FilterPreset preset;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final thumbs = ref.read(thumbnailServiceProvider);
    final path = ref.read(mediaRepositoryProvider).resolve(clip.sourcePath);
    final matrix = ColorMatrix.build(preset, 1, ColorAdjustments.neutral);
    return GestureDetector(
      onTap: onTap,
      child: Column(
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: selected ? AppColors.selection : Colors.transparent,
                width: 2,
              ),
            ),
            clipBehavior: Clip.antiAlias,
            child: ColorFiltered(
              colorFilter: ColorFilter.matrix(matrix),
              child: FutureBuilder<File?>(
                future: thumbs.frame(
                  path,
                  clip.isStill ? Duration.zero : clip.trimStart,
                  width: 160,
                ),
                builder: (context, snap) => snap.data == null
                    ? Container(
                        decoration: const BoxDecoration(
                          gradient: LinearGradient(colors: [Color(0xFF6E8BD6), Color(0xFFE39B6B)]),
                        ),
                      )
                    : Image.file(snap.data!, fit: BoxFit.cover, cacheWidth: 160),
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(preset.label, style: const TextStyle(fontSize: 11)),
        ],
      ),
    );
  }
}

// -------------------------------------------------------------------- adjust

class AdjustPanel extends ClipPanel {
  const AdjustPanel({super.key});

  @override
  String get title => 'Adjust';

  @override
  Widget buildForClip(BuildContext context, WidgetRef ref, VideoClip clip, int index) {
    final controller = ref.read(editorProvider.notifier);
    final a = clip.adjustments;

    Widget slider(String label, double value, ColorAdjustments Function(double v) apply) =>
        LabeledSlider(
          label: label,
          value: value,
          min: -1,
          max: 1,
          format: (v) => (v * 100).round().toString(),
          onChangeStart: (_) => controller.beginChange(),
          onChanged: (v) {
            // Gentle snap to neutral.
            final snapped = v.abs() < 0.03 ? 0.0 : v;
            controller.setAdjustments(clip.id, apply(snapped), live: true);
          },
        );

    return Column(
      children: [
        slider('Brightness', a.brightness, (v) => a.copyWith(brightness: v)),
        slider('Contrast', a.contrast, (v) => a.copyWith(contrast: v)),
        slider('Saturation', a.saturation, (v) => a.copyWith(saturation: v)),
        slider('Exposure', a.exposure, (v) => a.copyWith(exposure: v)),
        slider('Temperature', a.temperature, (v) => a.copyWith(temperature: v)),
        slider('Highlights', a.highlights, (v) => a.copyWith(highlights: v)),
        slider('Shadows', a.shadows, (v) => a.copyWith(shadows: v)),
        Row(
          children: [
            TextButton.icon(
              icon: const Icon(Icons.restart_alt),
              label: const Text('Reset'),
              onPressed: a.isNeutral
                  ? null
                  : () => controller.setAdjustments(clip.id, ColorAdjustments.neutral),
            ),
            const Spacer(),
            TextButton.icon(
              icon: const Icon(Icons.done_all),
              label: const Text('Apply look to all'),
              onPressed: () {
                controller.copyLookToAll(clip.id);
                showSnack(context, 'Filter and adjustments applied to all clips.');
              },
            ),
          ],
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------- transition

class TransitionPanel extends ClipPanel {
  const TransitionPanel({super.key});

  @override
  String get title => 'Transition';

  @override
  Widget buildForClip(BuildContext context, WidgetRef ref, VideoClip clip, int index) {
    final controller = ref.read(editorProvider.notifier);
    final clipCount = controller.project.clips.length;
    if (index >= clipCount - 1) {
      return const PanelHint(
        'Transitions go between two clips. Select a clip that has another clip after it.',
      );
    }
    final t = clip.transition;
    final effective = controller.timeline.transitionAfter(index);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Between clip ${index + 1} and ${index + 2}',
          style: const TextStyle(fontSize: 12, color: Colors.white60),
        ),
        const SizedBox(height: 8),
        ChipRow<TransitionType>(
          values: TransitionType.values,
          selected: t.type,
          label: (v) => v.label,
          onSelected: (v) => controller.setTransition(index, t.copyWith(type: v)),
        ),
        if (!t.isNone) ...[
          const SizedBox(height: 10),
          ChipRow<Duration>(
            values: ClipTransition.durations,
            selected: t.duration,
            label: (d) => '${d.inMilliseconds / 1000} s',
            onSelected: (d) => controller.setTransition(index, t.copyWith(duration: d)),
          ),
          if (effective < t.duration)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                'Shortened to ${effective.inMilliseconds / 1000} s to fit the clips.',
                style: const TextStyle(fontSize: 12, color: Colors.white60),
              ),
            ),
        ],
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            icon: const Icon(Icons.done_all),
            label: const Text('Apply to all'),
            onPressed: () {
              controller.setTransition(index, t, applyToAll: true);
              showSnack(context, 'Transition applied between all clips.');
            },
          ),
        ),
      ],
    );
  }
}
