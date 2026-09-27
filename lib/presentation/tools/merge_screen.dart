import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';

import '../../app/providers.dart';
import '../../core/utils/formatters.dart';
import '../../core/utils/id_generator.dart';
import '../../domain/entities/canvas_settings.dart';
import '../../domain/entities/project.dart';
import '../../domain/entities/project_timeline.dart';
import '../../domain/entities/video_clip.dart';
import '../../domain/repositories/media_repository.dart';
import '../../domain/usecases/project_usecases.dart';
import '../editor/editor_screen.dart';
import '../editor/panels/panel_common.dart';
import '../editor/playback/playback_controller.dart';
import '../editor/preview/clip_video_view.dart';
import '../export/export_screen.dart';
import '../widgets/app_dialogs.dart';
import '../widgets/media_import_flow.dart';

/// Merge tool: reorder, remove, preview the sequence, then export or open
/// in the full editor. Clips of different sizes are normalised onto one
/// canvas at export time.
class MergeScreen extends ConsumerStatefulWidget {
  const MergeScreen({super.key, required this.initial});
  final List<ImportedMedia> initial;

  @override
  ConsumerState<MergeScreen> createState() => _MergeScreenState();
}

class _MergeScreenState extends ConsumerState<MergeScreen> {
  late final List<ImportedMedia> _items = [...widget.initial];
  CanvasSettings _canvas = const CanvasSettings();
  PlaybackController? _playback;

  Project _buildProject({String? id, String name = 'Merged video'}) {
    final now = DateTime.now();
    return Project(
      id: id ?? 'merge-preview',
      name: name,
      createdAt: now,
      updatedAt: now,
      canvas: _canvas,
      exportSettings: ref.read(settingsProvider).defaultExport,
      clips: [
        for (final m in _items)
          VideoClip(
            // Stable ids per path keep the preview player pool reusable.
            id: m.relativePath,
            sourcePath: m.relativePath,
            media: m.info,
            trimStart: Duration.zero,
            trimEnd: m.info.duration,
          ),
      ],
    );
  }

  void _changed() {
    setState(() {});
    _playback?.updateProject(_buildProject());
  }

  @override
  void initState() {
    super.initState();
    _playback = PlaybackController(
      project: _buildProject(),
      resolveMedia: ref.read(mediaRepositoryProvider).resolve,
    )..seek(Duration.zero, fromUser: false);
  }

  @override
  void dispose() {
    _playback?.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    _playback?.pause();
    final media = await importVideos(context, ref);
    if (media.isNotEmpty) {
      _items.addAll(media);
      _changed();
    }
  }

  Future<Project> _saveAsProject() async {
    final project = await CreateProject(ref.read(projectRepositoryProvider))(
      _items,
      exportSettings: ref.read(settingsProvider).defaultExport,
    );
    final withCanvas = project.copyWith(canvas: _canvas);
    await ref.read(projectRepositoryProvider).save(withCanvas);
    await ref.read(projectsProvider.notifier).refresh();
    return withCanvas;
  }

  @override
  Widget build(BuildContext context) {
    final project = _buildProject();
    final timeline = ProjectTimeline(project);
    final playback = _playback!;

    return StudioTheme(
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Merge videos'),
          actions: [
            IconButton(tooltip: 'Add videos', onPressed: _add, icon: const Icon(Icons.add)),
          ],
        ),
        body: SafeArea(
          child: Column(
            children: [
              SizedBox(
                height: 220,
                child: _items.isEmpty
                    ? const Center(child: Text('Add at least two videos'))
                    : Center(
                        child: AspectRatio(
                          aspectRatio: timeline.canvasAspectRatio,
                          child: ColoredBox(
                            color: Colors.black,
                            child: ListenableBuilder(
                              listenable: playback,
                              builder: (context, _) {
                                final i = playback.activeIndex;
                                final c = playback.activeController;
                                if (i == null || c == null || i >= project.clips.length) {
                                  return const SizedBox.shrink();
                                }
                                return ClipVideoView(
                                  clip: project.clips[i],
                                  controller: c,
                                  fit: _canvas.fit,
                                );
                              },
                            ),
                          ),
                        ),
                      ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  children: [
                    ListenableBuilder(
                      listenable: playback,
                      builder: (context, _) => IconButton.filledTonal(
                        onPressed: _items.isEmpty ? null : playback.togglePlay,
                        icon: Icon(playback.isPlaying ? Icons.pause : Icons.play_arrow),
                      ),
                    ),
                    const SizedBox(width: 8),
                    const Text('Preview sequence'),
                    const Spacer(),
                    Text('Total ${Formatters.duration(timeline.duration)}'),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: ChipRow<AspectRatioPreset>(
                  values: AspectRatioPreset.values,
                  selected: _canvas.aspectRatio,
                  label: (a) => a.label,
                  onSelected: (a) {
                    _canvas = _canvas.copyWith(aspectRatio: a);
                    _changed();
                  },
                ),
              ),
              Expanded(
                child: ReorderableListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: _items.length,
                  onReorderItem: (oldIndex, newIndex) {
                    final item = _items.removeAt(oldIndex);
                    _items.insert(newIndex, item);
                    _changed();
                  },
                  itemBuilder: (context, i) {
                    final m = _items[i];
                    return ListTile(
                      key: ValueKey('${m.relativePath}#$i'),
                      leading: _Thumb(
                        path: ref.read(mediaRepositoryProvider).resolve(m.relativePath),
                      ),
                      title: Text(m.displayName, maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(
                        '${Formatters.duration(m.info.duration)} · ${m.info.displayWidth}×${m.info.displayHeight}',
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            tooltip: 'Remove',
                            icon: const Icon(Icons.close),
                            onPressed: () {
                              _items.removeAt(i);
                              _changed();
                            },
                          ),
                          ReorderableDragStartListener(
                            index: i,
                            child: const Icon(Icons.drag_handle),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: _items.isEmpty
                            ? null
                            : () async {
                                playback.pause();
                                try {
                                  final saved = await _saveAsProject();
                                  if (!context.mounted) return;
                                  await Navigator.of(context).pushReplacement(
                                    MaterialPageRoute(builder: (_) => EditorScreen(project: saved)),
                                  );
                                } catch (e) {
                                  if (context.mounted) await showAppError(context, e);
                                }
                              },
                        child: const Text('Open in editor'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton(
                        onPressed: _items.length < 2
                            ? null
                            : () {
                                playback.pause();
                                Navigator.of(context).push(
                                  MaterialPageRoute(
                                    builder: (_) => ExportScreen(
                                      project: _buildProject(id: newId(), name: 'Merged'),
                                    ),
                                  ),
                                );
                              },
                        child: const Text('Merge & export'),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Thumb extends ConsumerWidget {
  const _Thumb({required this.path});
  final String path;

  @override
  Widget build(BuildContext context, WidgetRef ref) => ClipRRect(
    borderRadius: BorderRadius.circular(6),
    child: SizedBox(
      width: 56,
      height: 40,
      child: FutureBuilder<File?>(
        future: ref.read(thumbnailServiceProvider).frame(path, Duration.zero),
        builder: (_, snap) => snap.data == null
            ? const ColoredBox(color: Color(0xFF232838))
            : Image.file(snap.data!, fit: BoxFit.cover, cacheWidth: 120),
      ),
    ),
  );
}
