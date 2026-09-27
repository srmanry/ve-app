import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/utils/formatters.dart';
import '../../../domain/entities/video_clip.dart';
import '../../widgets/app_dialogs.dart';
import '../editor_scope.dart';
import '../preview/crop_overlay.dart';
import '../state/editor_controller.dart';
import '../state/editor_state.dart';
import 'panel_common.dart';

/// Base for panels that act on the selected main-track clip.
abstract class ClipPanel extends ConsumerWidget {
  const ClipPanel({super.key});

  String get title;

  Widget buildForClip(BuildContext context, WidgetRef ref, VideoClip clip, int index);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final clip = ref.watch(editorProvider.select((s) => s.selectedClip));
    final index = ref.watch(editorProvider.select((s) => s.selectedClipIndex));
    final controller = ref.read(editorProvider.notifier);
    return ToolPanel(
      title: title,
      onClose: () => controller.openTool(null),
      child: clip == null || index == null
          ? const PanelHint('Tap a clip on the timeline to select it.')
          : buildForClip(context, ref, clip, index),
    );
  }
}

// ---------------------------------------------------------------------- trim

class TrimPanel extends ClipPanel {
  const TrimPanel({super.key});

  @override
  String get title => 'Trim';

  @override
  Widget buildForClip(BuildContext context, WidgetRef ref, VideoClip clip, int index) {
    if (clip.isStill) return _PhotoDuration(clip: clip, index: index);
    final controller = ref.read(editorProvider.notifier);
    final playback = EditorScope.playbackOf(context);
    final total = clip.media.duration.inMilliseconds.toDouble();
    const label = TextStyle(fontSize: 13);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('Start: ${Formatters.duration(clip.trimStart, showTenths: true)}', style: label),
            Text('End: ${Formatters.duration(clip.trimEnd, showTenths: true)}', style: label),
            Text('Duration: ${Formatters.duration(clip.duration, showTenths: true)}', style: label),
          ],
        ),
        RangeSlider(
          values: RangeValues(
            clip.trimStart.inMilliseconds.toDouble(),
            clip.trimEnd.inMilliseconds.toDouble(),
          ),
          min: 0,
          max: total,
          onChangeStart: (_) => controller.beginChange(),
          onChanged: (v) {
            controller.trimClip(
              clip.id,
              Duration(milliseconds: v.start.round()),
              Duration(milliseconds: v.end.round()),
              live: true,
            );
          },
          onChangeEnd: (v) {
            // Show the frame at the edited edge.
            final start = controller.timeline.clipStart(index);
            playback.seek(start);
          },
        ),
        const SizedBox(height: 4),
        Wrap(
          alignment: WrapAlignment.center,
          children: [
            PanelAction(
              icon: Icons.play_circle_outline,
              label: 'Preview',
              onTap: () {
                final t = controller.timeline;
                playback.playRange(t.clipStart(index), t.clipEnd(index));
              },
            ),
            PanelAction(
              icon: Icons.content_cut,
              label: 'Split',
              onTap: () {
                final error = controller.splitAt(playback.position.value);
                if (error != null) showSnack(context, error);
              },
            ),
            PanelAction(
              icon: Icons.copy_all_outlined,
              label: 'Duplicate',
              onTap: () => controller.duplicateClip(clip.id),
            ),
            PanelAction(
              icon: Icons.delete_outline,
              label: 'Delete',
              color: Theme.of(context).colorScheme.error,
              onTap: () => controller.deleteClip(clip.id),
            ),
          ],
        ),
      ],
    );
  }
}

/// Duration controls for a photo clip (photos have nothing to trim).
class _PhotoDuration extends ConsumerWidget {
  const _PhotoDuration({required this.clip, required this.index});
  final VideoClip clip;
  final int index;

  static const presets = [
    Duration(seconds: 1),
    Duration(seconds: 2),
    Duration(seconds: 3),
    Duration(seconds: 5),
    Duration(seconds: 8),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(editorProvider.notifier);
    final seconds = clip.duration.inMilliseconds / 1000;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Photo duration: ${seconds.toStringAsFixed(1)} s',
          style: const TextStyle(fontSize: 13),
        ),
        LabeledSlider(
          label: 'Show for',
          value: seconds.clamp(0.5, 20),
          min: 0.5,
          max: 20,
          divisions: 39,
          format: (v) => '${v.toStringAsFixed(1)}s',
          onChangeStart: (_) => controller.beginChange(),
          onChanged: (v) => controller.setStillDuration(
            clip.id,
            Duration(milliseconds: (v * 1000).round()),
            live: true,
          ),
        ),
        ChipRow<Duration>(
          values: presets,
          selected: clip.duration,
          label: (d) => '${d.inSeconds}s',
          onSelected: (d) => controller.setStillDuration(clip.id, d),
        ),
        Row(
          children: [
            TextButton.icon(
              icon: const Icon(Icons.done_all),
              label: const Text('Use for all photos'),
              onPressed: () {
                controller.setAllStillDurations(clip.duration);
                showSnack(context, 'All photos now show for ${seconds.toStringAsFixed(1)} s.');
              },
            ),
            const Spacer(),
            TextButton.icon(
              style: TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
              icon: const Icon(Icons.delete_outline),
              label: const Text('Delete'),
              onPressed: () => controller.deleteClip(clip.id),
            ),
          ],
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------- crop

class CropPanel extends ClipPanel {
  const CropPanel({super.key});

  @override
  String get title => 'Crop';

  @override
  Widget buildForClip(BuildContext context, WidgetRef ref, VideoClip clip, int index) {
    final controller = ref.read(editorProvider.notifier);
    final aspect = EditorScope.of(context).cropAspect;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Drag the frame or its corners in the preview.',
          style: TextStyle(fontSize: 12, color: Colors.white60),
        ),
        const SizedBox(height: 8),
        ValueListenableBuilder<CropAspect>(
          valueListenable: aspect,
          builder: (context, current, _) => ChipRow<CropAspect>(
            values: CropAspect.values,
            selected: current,
            label: (a) => a.label,
            onSelected: (a) {
              aspect.value = a;
              if (a.ratio != null) {
                controller.setCrop(clip.id, a.initialRect(clip.media.aspectRatio));
              }
            },
          ),
        ),
        const SizedBox(height: 8),
        Align(
          child: TextButton.icon(
            onPressed: clip.crop.isFull
                ? null
                : () {
                    aspect.value = CropAspect.free;
                    controller.setCrop(clip.id, CropRect.full);
                  },
            icon: const Icon(Icons.restart_alt),
            label: const Text('Reset crop'),
          ),
        ),
      ],
    );
  }
}

// -------------------------------------------------------------------- rotate

class RotatePanel extends ClipPanel {
  const RotatePanel({super.key});

  @override
  String get title => 'Rotate & Flip';

  @override
  Widget buildForClip(BuildContext context, WidgetRef ref, VideoClip clip, int index) {
    final c = ref.read(editorProvider.notifier);
    return Wrap(
      alignment: WrapAlignment.spaceEvenly,
      children: [
        PanelAction(
          icon: Icons.rotate_left,
          label: '90° left',
          onTap: () => c.rotateClip(clip.id, clockwise: false),
        ),
        PanelAction(
          icon: Icons.rotate_right,
          label: '90° right',
          onTap: () => c.rotateClip(clip.id, clockwise: true),
        ),
        PanelAction(
          icon: Icons.flip,
          label: 'Flip H',
          color: clip.flipHorizontal ? Theme.of(context).colorScheme.primary : null,
          onTap: () => c.flipClip(clip.id, horizontal: true),
        ),
        PanelAction(
          icon: Icons.flip_camera_android_outlined,
          label: 'Flip V',
          color: clip.flipVertical ? Theme.of(context).colorScheme.primary : null,
          onTap: () => c.flipClip(clip.id, horizontal: false),
        ),
      ],
    );
  }
}

// --------------------------------------------------------------------- speed

class SpeedPanel extends ClipPanel {
  const SpeedPanel({super.key});

  @override
  String get title => 'Speed';

  @override
  Widget buildForClip(BuildContext context, WidgetRef ref, VideoClip clip, int index) {
    if (clip.isStill) {
      return const PanelHint(
        'Speed doesn\'t apply to photos. Use Trim to set how long a photo shows.',
      );
    }
    final controller = ref.read(editorProvider.notifier);
    final original = clip.sourceDuration;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ChipRow<double>(
          values: VideoClip.speeds,
          selected: clip.speed,
          label: Formatters.speed,
          onSelected: (s) => controller.setSpeed(clip.id, s),
        ),
        const SizedBox(height: 12),
        Text(
          'Duration: ${Formatters.duration(original, showTenths: true)}'
          '  →  ${Formatters.duration(clip.duration, showTenths: true)}',
          style: const TextStyle(fontSize: 13),
        ),
        if (clip.media.hasAudio && clip.speed != 1.0)
          const Padding(
            padding: EdgeInsets.only(top: 4),
            child: Text(
              'Audio pitch is preserved.',
              style: TextStyle(fontSize: 12, color: Colors.white60),
            ),
          ),
      ],
    );
  }
}

// -------------------------------------------------------------------- volume

class VolumePanel extends ClipPanel {
  const VolumePanel({super.key});

  @override
  String get title => 'Clip volume';

  @override
  Widget buildForClip(BuildContext context, WidgetRef ref, VideoClip clip, int index) {
    final controller = ref.read(editorProvider.notifier);
    if (!clip.media.hasAudio) {
      return const PanelHint('This clip has no audio track.');
    }
    return Column(
      children: [
        LabeledSlider(
          label: 'Volume',
          value: clip.muted ? 0 : clip.volume,
          min: 0,
          max: 2,
          format: (v) => '${(v * 100).round()}%',
          onChangeStart: (_) => controller.beginChange(),
          onChanged: (v) => controller.setClipVolume(clip.id, v, live: true),
        ),
        Row(
          children: [
            Expanded(
              child: SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Mute original audio'),
                value: clip.muted,
                onChanged: (_) => controller.toggleClipMute(clip.id),
              ),
            ),
          ],
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            icon: const Icon(Icons.call_split),
            label: const Text('Extract audio to track'),
            onPressed: () async {
              try {
                await controller.detachAudio(clip.id);
                if (context.mounted) showSnack(context, 'Audio extracted to a new track.');
              } catch (e) {
                if (context.mounted) await showAppError(context, e);
              }
            },
          ),
        ),
      ],
    );
  }
}

/// Maps a tool to its panel widget.
Widget? clipPanelFor(EditorTool tool) => switch (tool) {
  EditorTool.trim => const TrimPanel(),
  EditorTool.crop => const CropPanel(),
  EditorTool.rotate => const RotatePanel(),
  EditorTool.speed => const SpeedPanel(),
  EditorTool.volume => const VolumePanel(),
  _ => null,
};
