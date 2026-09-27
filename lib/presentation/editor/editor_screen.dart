import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/formatters.dart';
import '../../domain/entities/project.dart';
import '../export/export_screen.dart';
import '../widgets/app_dialogs.dart';
import '../widgets/media_import_flow.dart';
import 'editor_scope.dart';
import 'panels/canvas_panel.dart';
import 'panels/clip_panels.dart';
import 'panels/effect_panels.dart';
import 'panels/layer_panels.dart';
import 'panels/logo_panel.dart';
import 'panels/look_panels.dart';
import 'playback/playback_controller.dart';
import 'preview/crop_overlay.dart';
import 'preview/preview_canvas.dart';
import 'state/editor_controller.dart';
import 'state/editor_state.dart';
import 'timeline/timeline_view.dart';

/// Full-screen editor for one project. Scopes a fresh [EditorController]
/// and [PlaybackController] to this screen.
class EditorScreen extends StatelessWidget {
  const EditorScreen({super.key, required this.project, this.initialTool});

  final Project project;
  final EditorTool? initialTool;

  static Future<void> open(BuildContext context, Project project, {EditorTool? tool}) =>
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => EditorScreen(project: project, initialTool: tool),
        ),
      );

  @override
  Widget build(BuildContext context) => StudioTheme(
    child: ProviderScope(
      overrides: [editorProvider.overrideWith(() => EditorController(project))],
      child: _EditorBody(initialTool: initialTool),
    ),
  );
}

class _EditorBody extends ConsumerStatefulWidget {
  const _EditorBody({this.initialTool});
  final EditorTool? initialTool;

  @override
  ConsumerState<_EditorBody> createState() => _EditorBodyState();
}

class _EditorBodyState extends ConsumerState<_EditorBody> {
  late final PlaybackController _playback;
  final _cropAspect = ValueNotifier(CropAspect.free);

  EditorController get _controller => ref.read(editorProvider.notifier);

  @override
  void initState() {
    super.initState();
    _playback = PlaybackController(
      project: ref.read(editorProvider).project,
      resolveMedia: ref.read(mediaRepositoryProvider).resolve,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      _playback.seek(Duration.zero, fromUser: false);
      if (widget.initialTool != null) _controller.openTool(widget.initialTool);
      await _checkMissingMedia();
    });
  }

  @override
  void dispose() {
    _playback.dispose();
    _cropAspect.dispose();
    super.dispose();
  }

  Future<void> _checkMissingMedia() async {
    final missing = await _controller.missingMedia();
    if (missing.isEmpty || !mounted) return;
    final remove = await confirm(
      context,
      title: 'Missing files',
      message:
          '${missing.length} file(s) used in this project are no longer on this '
          'device. Remove them from the timeline to keep editing?',
      confirmLabel: 'Remove',
    );
    if (remove) _controller.removeMissingMedia(missing);
  }

  Future<void> _save() async {
    try {
      await _controller.save();
      if (mounted) showSnack(context, 'Project saved');
    } catch (e) {
      if (mounted) await showAppError(context, e);
    }
  }

  Future<void> _onBack() async {
    _playback.pause();
    final dirty = ref.read(editorProvider).isDirty;
    if (!dirty) {
      if (mounted) Navigator.pop(context);
      return;
    }
    final choice = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Save changes?'),
        content: const Text('You have unsaved edits in this project.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, 'discard'),
            child: const Text('Discard'),
          ),
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, 'save'), child: const Text('Save')),
        ],
      ),
    );
    if (choice == null || !mounted) return;
    if (choice == 'save') await _save();
    if (mounted) Navigator.pop(context);
  }

  Future<void> _addClips() async {
    _playback.pause();
    final added = await importOrRecord(context, ref);
    if (!added.isEmpty) {
      _controller.addClips(added.media, recorded: added.recorded, logo: added.logo);
    }
  }

  Future<void> _export() async {
    _playback.pause();
    final project = ref.read(editorProvider).project;
    if (project.clips.isEmpty) {
      showSnack(context, 'Add a video clip first.');
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) =>
            ExportScreen(project: project, onSettingsChanged: _controller.setExportSettings),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(editorProvider.select((s) => s.project), (_, next) => _playback.updateProject(next));
    final busy = ref.watch(editorProvider.select((s) => s.busyMessage));
    final tool = ref.watch(editorProvider.select((s) => s.activeTool));
    final media = MediaQuery.of(context);
    final timelineHeight = media.size.height < 700 ? 132.0 : 168.0;

    return EditorScope(
      playback: _playback,
      cropAspect: _cropAspect,
      child: PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) unawaited(_onBack());
        },
        child: Scaffold(
          backgroundColor: AppColors.darkBackground,
          body: Stack(
            children: [
              SafeArea(
                child: Column(
                  children: [
                    _TopBar(onBack: _onBack, onSave: _save, onExport: _export),
                    const Expanded(
                      child: Padding(
                        padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        child: PreviewCanvas(),
                      ),
                    ),
                    _TransportBar(playback: _playback),
                    SizedBox(
                      height: timelineHeight,
                      child: TimelineView(onAddClip: _addClips),
                    ),
                    const Divider(),
                    AnimatedSize(
                      duration: const Duration(milliseconds: 180),
                      alignment: Alignment.bottomCenter,
                      child: ConstrainedBox(
                        constraints: BoxConstraints(maxHeight: media.size.height * 0.38),
                        child: tool == null || tool == EditorTool.split
                            ? _ToolBar(playback: _playback)
                            : _panelFor(tool),
                      ),
                    ),
                  ],
                ),
              ),
              if (busy != null)
                Positioned.fill(
                  child: ColoredBox(
                    color: Colors.black54,
                    child: Center(
                      child: Card(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const CircularProgressIndicator(strokeWidth: 3),
                              const SizedBox(width: 20),
                              Text(busy),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _panelFor(EditorTool tool) =>
      clipPanelFor(tool) ??
      switch (tool) {
        EditorTool.filter => const FilterPanel(),
        EditorTool.adjust => const AdjustPanel(),
        EditorTool.transition => const TransitionPanel(),
        EditorTool.audio => const AudioPanel(),
        EditorTool.text => const TextPanel(),
        EditorTool.sticker => const StickerPanel(),
        EditorTool.pip => const PipPanel(),
        EditorTool.canvas => const CanvasPanel(),
        EditorTool.logo => const LogoPanel(),
        EditorTool.effects => const EffectsPanel(),
        EditorTool.denoise => const DenoisePanel(),
        EditorTool.removeBackground => const RemoveBackgroundPanel(),
        _ => _ToolBar(playback: _playback),
      };
}

class _TopBar extends ConsumerWidget {
  const _TopBar({required this.onBack, required this.onSave, required this.onExport});

  final VoidCallback onBack;
  final VoidCallback onSave;
  final VoidCallback onExport;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final name = ref.watch(editorProvider.select((s) => s.project.name));
    final canUndo = ref.watch(editorProvider.select((s) => s.canUndo));
    final canRedo = ref.watch(editorProvider.select((s) => s.canRedo));
    final dirty = ref.watch(editorProvider.select((s) => s.isDirty));
    final c = ref.read(editorProvider.notifier);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        children: [
          IconButton(tooltip: 'Back', onPressed: onBack, icon: const Icon(Icons.arrow_back)),
          Expanded(
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () async {
                final newName = await promptText(context, title: 'Rename project', initial: name);
                if (newName != null) c.rename(newName);
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
                child: Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
                ),
              ),
            ),
          ),
          IconButton(
            tooltip: 'Undo',
            onPressed: canUndo ? c.undo : null,
            icon: const Icon(Icons.undo),
          ),
          IconButton(
            tooltip: 'Redo',
            onPressed: canRedo ? c.redo : null,
            icon: const Icon(Icons.redo),
          ),
          IconButton(
            tooltip: 'Save',
            onPressed: onSave,
            icon: Badge(
              isLabelVisible: dirty,
              smallSize: 7,
              child: const Icon(Icons.save_outlined),
            ),
          ),
          const SizedBox(width: 4),
          FilledButton(
            onPressed: onExport,
            style: FilledButton.styleFrom(
              minimumSize: const Size(0, 38),
              padding: const EdgeInsets.symmetric(horizontal: 14),
            ),
            child: const Text('Export'),
          ),
          const SizedBox(width: 8),
        ],
      ),
    );
  }
}

class _TransportBar extends ConsumerWidget {
  const _TransportBar({required this.playback});
  final PlaybackController playback;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hasSelection = ref.watch(
      editorProvider.select((s) => s.selection.kind != SelectionKind.none),
    );
    final c = ref.read(editorProvider.notifier);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          ValueListenableBuilder<Duration>(
            valueListenable: playback.position,
            builder: (context, t, _) => Text(
              '${Formatters.duration(t, showTenths: true)} / '
              '${Formatters.duration(playback.duration, showTenths: true)}',
              style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()], fontSize: 13),
            ),
          ),
          const Spacer(),
          ListenableBuilder(
            listenable: playback,
            builder: (context, _) => IconButton.filledTonal(
              tooltip: playback.isPlaying ? 'Pause' : 'Play',
              onPressed: playback.togglePlay,
              icon: Icon(playback.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded),
            ),
          ),
          const Spacer(),
          IconButton(
            tooltip: 'Split at playhead',
            onPressed: () {
              final error = c.splitAt(playback.position.value);
              if (error != null) showSnack(context, error);
            },
            icon: const Icon(Icons.content_cut),
          ),
          IconButton(
            tooltip: 'Delete selected',
            onPressed: hasSelection ? c.deleteSelection : null,
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      ),
    );
  }
}

class _ToolBar extends ConsumerWidget {
  const _ToolBar({required this.playback});
  final PlaybackController playback;

  static const _icons = <EditorTool, IconData>{
    EditorTool.trim: Icons.straighten,
    EditorTool.split: Icons.content_cut,
    EditorTool.crop: Icons.crop,
    EditorTool.rotate: Icons.rotate_90_degrees_cw_outlined,
    EditorTool.speed: Icons.speed,
    EditorTool.volume: Icons.volume_up_outlined,
    EditorTool.audio: Icons.music_note_outlined,
    EditorTool.text: Icons.title,
    EditorTool.sticker: Icons.emoji_emotions_outlined,
    EditorTool.filter: Icons.auto_awesome_outlined,
    EditorTool.adjust: Icons.tune,
    EditorTool.transition: Icons.swap_horiz,
    EditorTool.pip: Icons.picture_in_picture_alt_outlined,
    EditorTool.canvas: Icons.aspect_ratio,
    EditorTool.logo: Icons.branding_watermark_outlined,
    EditorTool.effects: Icons.auto_fix_high,
    EditorTool.denoise: Icons.noise_control_off,
    EditorTool.removeBackground: Icons.person_remove_outlined,
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = ref.read(editorProvider.notifier);
    return SizedBox(
      height: 76,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        children: [
          for (final tool in EditorTool.values)
            InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () {
                if (tool == EditorTool.split) {
                  final error = c.splitAt(playback.position.value);
                  if (error != null) showSnack(context, error);
                  return;
                }
                c.openTool(tool);
              },
              child: SizedBox(
                width: 64,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(_icons[tool], size: 24),
                    const SizedBox(height: 6),
                    Text(tool.label, style: const TextStyle(fontSize: 11)),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
