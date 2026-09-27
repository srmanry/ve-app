import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../../app/providers.dart';
import '../../../core/theme/app_theme.dart';
import '../../../domain/entities/video_clip.dart';
import '../../../domain/entities/video_effect.dart';
import '../../../domain/repositories/media_repository.dart';
import '../../../services/ai/background_removal_service.dart';
import '../../../services/video/video_processing_service.dart';
import '../../exports/player_screen.dart';
import '../../widgets/app_dialogs.dart';
import '../../widgets/media_import_flow.dart';
import '../editor_scope.dart';
import '../state/editor_controller.dart';
import 'clip_panels.dart';
import 'panel_common.dart';

// ------------------------------------------------------------------- effects

class EffectsPanel extends ClipPanel {
  const EffectsPanel({super.key});

  @override
  String get title => 'Effects';

  static IconData _icon(VideoEffect e) => switch (e) {
    VideoEffect.none => Icons.block,
    VideoEffect.blur => Icons.blur_on,
    VideoEffect.vignette => Icons.vignette_outlined,
    VideoEffect.mirror => Icons.flip,
    VideoEffect.invert => Icons.invert_colors,
    VideoEffect.glitch => Icons.auto_awesome_mosaic_outlined,
    VideoEffect.grain => Icons.grain,
    VideoEffect.pixelate => Icons.grid_on,
    VideoEffect.sharpen => Icons.details,
  };

  @override
  Widget buildForClip(BuildContext context, WidgetRef ref, VideoClip clip, int index) {
    final controller = ref.read(editorProvider.notifier);
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 78,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: VideoEffect.values.length,
            separatorBuilder: (_, _) => const SizedBox(width: 8),
            itemBuilder: (context, i) {
              final e = VideoEffect.values[i];
              final selected = clip.effect == e;
              return InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () => controller.setEffect(clip.id, e),
                child: Container(
                  width: 70,
                  decoration: BoxDecoration(
                    color: selected
                        ? scheme.primary.withValues(alpha: 0.2)
                        : scheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: selected ? scheme.primary : Colors.transparent,
                      width: 1.5,
                    ),
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(_icon(e), color: selected ? scheme.primary : null),
                      const SizedBox(height: 6),
                      Text(e.label, style: const TextStyle(fontSize: 11)),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
        if (clip.effect != VideoEffect.none) ...[
          const SizedBox(height: 8),
          LabeledSlider(
            label: 'Intensity',
            value: clip.effectIntensity,
            min: 0.05,
            max: 1,
            format: (v) => '${(v * 100).round()}%',
            onChangeStart: (_) => controller.beginChange(),
            onChanged: (v) => controller.setEffectIntensity(clip.id, v, live: true),
          ),
          if (!clip.effect.livePreview)
            Text(
              '${clip.effect.label} is subtle in the preview; it is applied in full on export.',
              style: TextStyle(fontSize: 12, color: context.mutedColor),
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              icon: const Icon(Icons.done_all),
              label: const Text('Apply to all clips'),
              onPressed: () {
                controller.setEffect(clip.id, clip.effect, applyToAll: true);
                showSnack(context, '${clip.effect.label} applied to all clips.');
              },
            ),
          ),
        ],
      ],
    );
  }
}

// ------------------------------------------------------------------- denoise

class DenoisePanel extends ClipPanel {
  const DenoisePanel({super.key});

  @override
  String get title => 'Remove noise';

  @override
  Widget buildForClip(BuildContext context, WidgetRef ref, VideoClip clip, int index) {
    final controller = ref.read(editorProvider.notifier);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Audio noise (hiss, hum, wind, background)',
          style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
        ),
        const SizedBox(height: 6),
        if (!clip.media.hasAudio)
          Text('This clip has no audio.', style: TextStyle(color: context.mutedColor))
        else ...[
          ChipRow<DenoiseLevel>(
            values: DenoiseLevel.values,
            selected: clip.audioDenoise,
            label: (l) => l.label,
            onSelected: (l) => controller.setAudioDenoise(clip.id, l),
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              TextButton.icon(
                icon: const Icon(Icons.hearing_outlined),
                label: const Text('Listen: before'),
                onPressed: () => _listen(context, ref, clip, DenoiseLevel.off),
              ),
              TextButton.icon(
                icon: const Icon(Icons.graphic_eq),
                label: const Text('Listen: after'),
                onPressed: clip.audioDenoise == DenoiseLevel.off
                    ? null
                    : () => _listen(context, ref, clip, clip.audioDenoise),
              ),
            ],
          ),
        ],
        const SizedBox(height: 8),
        const Text(
          'Video noise (grain in dark or low-light footage)',
          style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
        ),
        const SizedBox(height: 6),
        ChipRow<DenoiseLevel>(
          values: DenoiseLevel.values,
          selected: clip.videoDenoise,
          label: (l) => l.label,
          onSelected: (l) => controller.setVideoDenoise(clip.id, l),
        ),
        const SizedBox(height: 6),
        Text(
          'Noise removal is applied when you export.',
          style: TextStyle(fontSize: 12, color: context.mutedColor),
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            icon: const Icon(Icons.done_all),
            label: const Text('Apply to all clips'),
            onPressed: () {
              controller.setAudioDenoise(clip.id, clip.audioDenoise, applyToAll: true);
              controller.setVideoDenoise(clip.id, clip.videoDenoise, applyToAll: true);
              showSnack(context, 'Noise removal applied to all clips.');
            },
          ),
        ),
      ],
    );
  }

  /// Renders ~6 s of the clip's audio around the playhead (with or without
  /// noise removal) and plays it, so the difference can be heard.
  Future<void> _listen(
    BuildContext context,
    WidgetRef ref,
    VideoClip clip,
    DenoiseLevel level,
  ) async {
    final playback = EditorScope.playbackOf(context);
    playback.pause();
    final controller = ref.read(editorProvider.notifier);
    final index = controller.project.clips.indexWhere((c) => c.id == clip.id);
    final clipStart = controller.timeline.clipStart(index);
    var local = playback.position.value - clipStart;
    if (local < Duration.zero || local > clip.duration) local = Duration.zero;
    final sourceStart = clip.localToSource(local);
    final remaining = clip.trimEnd - sourceStart;
    final length = remaining < const Duration(seconds: 6) ? remaining : const Duration(seconds: 6);

    final paths = ref.read(appPathsProvider);
    final dir = await paths.createJobDir('listen');
    final out = p.join(dir.path, 'sample.m4a');
    try {
      if (!context.mounted) return;
      await runWithProgress(context, (status) async {
        final task = ref
            .read(videoProcessingProvider)
            .extractAudio(
              AudioExtractRequest(
                input: ref.read(mediaRepositoryProvider).resolve(clip.sourcePath),
                output: out,
                format: AudioOutputFormat.m4a,
                start: sourceStart,
                duration: length,
                denoise: level,
              ),
            );
        await task.done;
      }, initialStatus: level == DenoiseLevel.off ? 'Preparing sample…' : 'Removing noise…');
      if (!context.mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => PlayerScreen(
            path: out,
            title: level == DenoiseLevel.off ? 'Original audio' : 'Noise removed (${level.label})',
          ),
        ),
      );
    } catch (e) {
      if (context.mounted) await showAppError(context, e);
    } finally {
      if (await Directory(dir.path).exists()) await Directory(dir.path).delete(recursive: true);
    }
  }
}

// ------------------------------------------------------- remove background

enum _FillKind { blur, color, photo }

class RemoveBackgroundPanel extends ClipPanel {
  const RemoveBackgroundPanel({super.key});

  @override
  String get title => 'Remove background (AI)';

  @override
  Widget buildForClip(BuildContext context, WidgetRef ref, VideoClip clip, int index) =>
      _RemoveBackgroundBody(key: ValueKey(clip.id), clip: clip);
}

class _RemoveBackgroundBody extends ConsumerStatefulWidget {
  const _RemoveBackgroundBody({super.key, required this.clip});
  final VideoClip clip;

  @override
  ConsumerState<_RemoveBackgroundBody> createState() => _RemoveBackgroundBodyState();
}

class _RemoveBackgroundBodyState extends ConsumerState<_RemoveBackgroundBody> {
  _FillKind _kind = _FillKind.blur;
  int _color = 0xFF00C853;
  String? _photoPath;

  BackgroundFill? get _fill => switch (_kind) {
    _FillKind.blur => const BackgroundFill.blur(),
    _FillKind.color => BackgroundFill.color(_color),
    _FillKind.photo => _photoPath == null ? null : BackgroundFill.image(_photoPath!),
  };

  Future<void> _pickPhoto() async {
    final photos = await importPhotos(context, ref);
    if (photos.isEmpty) return;
    setState(() {
      _kind = _FillKind.photo;
      _photoPath = ref.read(mediaRepositoryProvider).resolve(photos.first.relativePath);
    });
  }

  Future<void> _run() async {
    final fill = _fill;
    if (fill == null) return;
    EditorScope.playbackOf(context).pause();
    final job = ref.read(backgroundRemovalProvider).start(widget.clip, fill);
    final media = await showDialog<ImportedMedia?>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _BackgroundProgressDialog(job: job),
    );
    if (media == null || !mounted) return;
    ref.read(editorProvider.notifier).replaceClipSource(widget.clip.id, media);
    showSnack(context, 'Background replaced. Undo to restore the original.');
  }

  @override
  Widget build(BuildContext context) {
    final clip = widget.clip;
    final seconds = clip.sourceDuration.inMilliseconds / 1000;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Finds people in the clip and replaces everything behind them. '
          'Runs on your device — nothing is uploaded. Works best with one or two people '
          'in clear view.',
          style: TextStyle(fontSize: 12, color: context.mutedColor),
        ),
        const SizedBox(height: 10),
        const Text('New background', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
        const SizedBox(height: 6),
        SegmentedButton<_FillKind>(
          segments: const [
            ButtonSegment(value: _FillKind.blur, icon: Icon(Icons.blur_on), label: Text('Blur')),
            ButtonSegment(
              value: _FillKind.color,
              icon: Icon(Icons.palette_outlined),
              label: Text('Color'),
            ),
            ButtonSegment(
              value: _FillKind.photo,
              icon: Icon(Icons.image_outlined),
              label: Text('Photo'),
            ),
          ],
          selected: {_kind},
          onSelectionChanged: (v) {
            if (v.first == _FillKind.photo && _photoPath == null) {
              _pickPhoto();
            } else {
              setState(() => _kind = v.first);
            }
          },
        ),
        const SizedBox(height: 8),
        if (_kind == _FillKind.color)
          ColorSwatchRow(
            selected: _color,
            onSelected: (c) {
              if (c != null) setState(() => _color = c);
            },
          ),
        if (_kind == _FillKind.photo && _photoPath != null)
          Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.file(
                  File(_photoPath!),
                  width: 56,
                  height: 56,
                  fit: BoxFit.cover,
                  cacheWidth: 160,
                ),
              ),
              TextButton(onPressed: _pickPhoto, child: const Text('Change photo')),
            ],
          ),
        const SizedBox(height: 8),
        if (!clip.isStill && seconds > 60)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(
              'This clip is ${seconds.round()} s long; processing may take a few minutes. '
              'Split or trim it first to go faster.',
              style: TextStyle(fontSize: 12, color: context.mutedColor),
            ),
          ),
        FilledButton.icon(
          onPressed: _fill == null ? null : _run,
          icon: const Icon(Icons.person_remove_outlined),
          label: Text(clip.isStill ? 'Remove photo background' : 'Remove background'),
        ),
      ],
    );
  }
}

class _BackgroundProgressDialog extends StatefulWidget {
  const _BackgroundProgressDialog({required this.job});
  final BackgroundRemovalJob job;

  @override
  State<_BackgroundProgressDialog> createState() => _BackgroundProgressDialogState();
}

class _BackgroundProgressDialogState extends State<_BackgroundProgressDialog> {
  BackgroundRemovalProgress _progress = const BackgroundRemovalProgress('Starting…', 0);

  @override
  void initState() {
    super.initState();
    widget.job.progress.listen((p) {
      if (mounted) setState(() => _progress = p);
    });
    widget.job.result.then(
      (media) {
        if (mounted) Navigator.of(context).pop(media);
      },
      onError: (Object e) async {
        if (!mounted) return;
        Navigator.of(context).pop();
        await showAppError(context, e);
      },
    );
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: false,
    child: AlertDialog(
      title: const Text('Removing background'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          LinearProgressIndicator(value: _progress.fraction),
          const SizedBox(height: 12),
          Text('${_progress.label}  ${(_progress.fraction * 100).floor()}%'),
        ],
      ),
      actions: [TextButton(onPressed: widget.job.cancel, child: const Text('Cancel'))],
    ),
  );
}
