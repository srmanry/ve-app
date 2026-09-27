import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';

import '../../../domain/entities/canvas_settings.dart';
import '../../../domain/entities/pip_layer.dart';
import '../../../domain/entities/project.dart';
import '../../../domain/entities/timeline_item.dart';
import '../../../domain/entities/transition.dart';
import '../../../domain/entities/video_effect.dart';
import '../../../services/overlay/overlay_painter.dart';
import '../editor_scope.dart';
import '../playback/playback_controller.dart';
import '../state/editor_controller.dart';
import '../state/editor_state.dart';
import 'clip_video_view.dart';
import 'effect_preview.dart';
import 'crop_overlay.dart';
import 'layer_painters.dart';
import 'transformable_layer.dart';

/// The canvas preview: main clip, PIP videos, text and stickers composited
/// in the project's aspect ratio, with direct manipulation of layers.
class PreviewCanvas extends ConsumerWidget {
  const PreviewCanvas({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final project = ref.watch(editorProvider.select((s) => s.project));
    final aspect = ref.watch(editorProvider.select((s) => s.timeline.canvasAspectRatio));
    final cropping = ref.watch(editorProvider.select((s) => s.activeTool == EditorTool.crop));
    final playback = EditorScope.playbackOf(context);

    if (project.clips.isEmpty) {
      return const Center(
        child: Text('Add a video to start editing', style: TextStyle(color: Colors.white54)),
      );
    }

    return Center(
      child: AspectRatio(
        aspectRatio: aspect,
        child: LayoutBuilder(
          builder: (context, box) {
            final canvasSize = Size(box.maxWidth, box.maxHeight);
            return ClipRect(
              child: ColoredBox(
                color: Color(project.canvas.backgroundColor),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    _MainVideo(playback: playback, project: project, cropping: cropping),
                    if (!cropping)
                      ValueListenableBuilder<Duration>(
                        valueListenable: playback.position,
                        builder: (context, t, _) =>
                            _Layers(project: project, time: t, canvasSize: canvasSize),
                      ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _MainVideo extends ConsumerWidget {
  const _MainVideo({required this.playback, required this.project, required this.cropping});

  final PlaybackController playback;
  final Project project;
  final bool cropping;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListenableBuilder(
      listenable: playback,
      builder: (context, _) {
        final index = playback.activeIndex;
        final controller = playback.activeController;
        if (playback.activeFailed) {
          return const _PreviewMessage('Preview unavailable for this clip.\nIt will still export.');
        }
        if (index == null || index >= project.clips.length) {
          return const Center(child: CircularProgressIndicator(strokeWidth: 2));
        }
        final clip = project.clips[index];
        // Photos render directly; videos need their player to be ready.
        final stillPath = clip.isStill ? playback.resolveMedia(clip.sourcePath) : null;
        if (stillPath == null && controller == null) {
          return const Center(child: CircularProgressIndicator(strokeWidth: 2));
        }

        if (cropping) {
          final selected = ref.watch(editorProvider.select((s) => s.selectedClip));
          final target = selected ?? clip;
          return ValueListenableBuilder<CropAspect>(
            valueListenable: EditorScope.of(context).cropAspect,
            builder: (context, aspect, _) => Stack(
              fit: StackFit.expand,
              children: [
                ClipVideoView(
                  clip: clip,
                  controller: controller,
                  stillPath: stillPath,
                  fit: CanvasFit.fit,
                  showCrop: false,
                  showGeometry: false,
                ),
                if (target.id == clip.id)
                  CropOverlay(
                    frameAspect: clip.media.aspectRatio,
                    crop: target.crop,
                    aspect: aspect,
                    onChangeStart: () => ref.read(editorProvider.notifier).beginChange(),
                    onChanged: (rect) =>
                        ref.read(editorProvider.notifier).setCrop(target.id, rect, live: true),
                  )
                else
                  const _PreviewMessage('Move the playhead to the selected clip to crop it.'),
              ],
            ),
          );
        }

        final outputWidth = playback.timeline.outputSize(project.exportSettings).width;
        final video = ClipVideoView(
          clip: clip,
          controller: controller,
          stillPath: stillPath,
          fit: project.canvas.fit,
        );
        return ValueListenableBuilder<Duration>(
          valueListenable: playback.position,
          builder: (context, t, child) => _TransitionEffect(
            project: project,
            time: t,
            timelineIndex: index,
            playback: playback,
            child: clip.effect == VideoEffect.none
                ? child!
                : EffectPreview(
                    effect: clip.effect,
                    intensity: clip.effectIntensity,
                    outputWidth: outputWidth,
                    time: t,
                    child: child!,
                  ),
          ),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => ref
                .read(editorProvider.notifier)
                .select(EditorSelection(SelectionKind.clip, clip.id)),
            child: video,
          ),
        );
      },
    );
  }
}

/// Approximates transitions in the preview (the export uses exact FFmpeg
/// xfade): fades dip through the background, slide/zoom move the frame.
class _TransitionEffect extends StatelessWidget {
  const _TransitionEffect({
    required this.project,
    required this.time,
    required this.timelineIndex,
    required this.playback,
    required this.child,
  });

  final Project project;
  final Duration time;
  final int timelineIndex;
  final PlaybackController playback;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final active = playback.timeline.transitionAt(time);
    if (active == null) return child;
    final type = project.clips[active.fromIndex].transition.type;
    final p = active.progress;
    final outgoing = p < 0.5;
    switch (type) {
      case TransitionType.fade:
      case TransitionType.crossDissolve:
        return Opacity(opacity: (1 - 2 * p).abs().clamp(0.0, 1.0), child: child);
      case TransitionType.slide:
        return FractionalTranslation(translation: Offset(outgoing ? -p : 1 - p, 0), child: child);
      case TransitionType.zoom:
        return Transform.scale(
          scale: outgoing ? 1 + p : 2 - p,
          child: Opacity(opacity: (1 - 2 * p).abs().clamp(0.2, 1.0), child: child),
        );
      case TransitionType.none:
        return child;
    }
  }
}

class _Layers extends ConsumerWidget {
  const _Layers({required this.project, required this.time, required this.canvasSize});

  final Project project;
  final Duration time;
  final Size canvasSize;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selection = ref.watch(editorProvider.select((s) => s.selection));
    final controller = ref.read(editorProvider.notifier);
    final playback = EditorScope.playbackOf(context);

    final children = <Widget>[];

    for (final pip in project.pipLayers.where((l) => l.isActiveAt(time))) {
      children.add(_pipLayer(pip, selection, controller, playback));
    }
    for (final text in project.textLayers.where((l) => l.isActiveAt(time))) {
      children.add(
        TransformableLayer(
          key: ValueKey(text.id),
          canvasSize: canvasSize,
          contentSize: OverlayPainter.measureText(text, canvasSize),
          transform: text.transform,
          selected: selection.isSelected(SelectionKind.text, text.id),
          onSelect: () => controller.select(EditorSelection(SelectionKind.text, text.id)),
          onGestureStart: controller.beginChange,
          onTransform: (t) =>
              controller.updateText(text.id, (l) => l.copyWith(transform: t), live: true),
          child: CustomPaint(painter: TextLayerPainter(text, canvasSize)),
        ),
      );
    }
    for (final sticker in project.stickerLayers.where((l) => l.isActiveAt(time))) {
      children.add(
        TransformableLayer(
          key: ValueKey(sticker.id),
          canvasSize: canvasSize,
          contentSize: OverlayPainter.stickerBaseSize(canvasSize),
          transform: sticker.transform,
          selected: selection.isSelected(SelectionKind.sticker, sticker.id),
          onSelect: () => controller.select(EditorSelection(SelectionKind.sticker, sticker.id)),
          onGestureStart: controller.beginChange,
          onTransform: (t) =>
              controller.updateSticker(sticker.id, (l) => l.copyWith(transform: t), live: true),
          child: sticker.sticker.isImage
              ? Opacity(
                  opacity: sticker.opacity.clamp(0.0, 1.0),
                  child: Image.file(
                    File(playback.resolveMedia(sticker.sticker.value as String)),
                    fit: BoxFit.contain,
                    gaplessPlayback: true,
                    errorBuilder: (_, _, _) => const Icon(Icons.broken_image_outlined),
                  ),
                )
              : CustomPaint(painter: StickerLayerPainter(sticker, canvasSize)),
        ),
      );
    }
    return Stack(children: children);
  }

  Widget _pipLayer(
    PipLayer pip,
    EditorSelection selection,
    EditorController controller,
    PlaybackController playback,
  ) {
    final aspect = pip.media.aspectRatio;
    final pipController = playback.pipController(pip.id);
    return TransformableLayer(
      key: ValueKey(pip.id),
      canvasSize: canvasSize,
      // scale 1.0 = full canvas width.
      contentSize: Size(canvasSize.width, canvasSize.width / aspect),
      transform: pip.transform,
      minScale: 0.1,
      maxScale: 1.0,
      selected: selection.isSelected(SelectionKind.pip, pip.id),
      onSelect: () => controller.select(EditorSelection(SelectionKind.pip, pip.id)),
      onGestureStart: controller.beginChange,
      onTransform: (t) => controller.updatePip(pip.id, (l) => l.copyWith(transform: t), live: true),
      child: pipController == null
          ? const ColoredBox(color: Colors.black54)
          : VideoPlayer(pipController),
    );
  }
}

class _PreviewMessage extends StatelessWidget {
  const _PreviewMessage(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: const TextStyle(color: Colors.white70, fontSize: 13),
      ),
    ),
  );
}
