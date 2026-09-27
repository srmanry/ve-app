import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../app/providers.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/formatters.dart';
import '../../core/utils/id_generator.dart';
import '../../domain/entities/audio_track.dart';
import '../../domain/entities/canvas_settings.dart';
import '../../domain/entities/project.dart';
import '../../domain/entities/project_timeline.dart';
import '../../domain/entities/transition.dart';
import '../../domain/entities/video_clip.dart';
import '../../domain/repositories/media_repository.dart';
import '../editor/editor_screen.dart';
import '../editor/panels/panel_common.dart';
import '../widgets/app_dialogs.dart';
import '../widgets/media_import_flow.dart';

/// Photos + music → video. Builds a normal project (photo clips, transitions,
/// a music track) and opens it in the editor, where everything stays
/// editable: order, timing, text, stickers, filters, export.
class SlideshowScreen extends ConsumerStatefulWidget {
  const SlideshowScreen({super.key, required this.photos});
  final List<ImportedMedia> photos;

  @override
  ConsumerState<SlideshowScreen> createState() => _SlideshowScreenState();
}

class _SlideshowScreenState extends ConsumerState<SlideshowScreen> {
  static const _durations = [
    Duration(seconds: 2),
    Duration(seconds: 3),
    Duration(seconds: 4),
    Duration(seconds: 5),
    Duration(seconds: 8),
  ];
  static const _aspects = [
    AspectRatioPreset.portrait9x16,
    AspectRatioPreset.square1x1,
    AspectRatioPreset.portrait4x5,
    AspectRatioPreset.landscape16x9,
    AspectRatioPreset.original,
  ];
  static const _transitionLength = Duration(milliseconds: 500);

  late final List<ImportedMedia> _photos = [...widget.photos];
  Duration _perPhoto = const Duration(seconds: 3);
  TransitionType _transition = TransitionType.fade;
  CanvasSettings _canvas = const CanvasSettings(
    aspectRatio: AspectRatioPreset.portrait9x16,
    fit: CanvasFit.fill,
  );
  ImportedMedia? _music;
  bool _matchMusic = false;
  bool _creating = false;

  /// Photo duration actually used: either the chosen one, or stretched so
  /// the slideshow lasts exactly as long as the song.
  Duration get _effectivePerPhoto {
    final music = _music;
    if (!_matchMusic || music == null || _photos.isEmpty) return _perPhoto;
    final n = _photos.length;
    final overlap = _transition == TransitionType.none ? Duration.zero : _transitionLength;
    // total = n·d − (n−1)·t  ⇒  d = (total + (n−1)·t) / n
    final us = (music.info.duration.inMicroseconds + (n - 1) * overlap.inMicroseconds) ~/ n;
    return Duration(microseconds: math.max(us, 500000));
  }

  Project _buildProject() {
    final now = DateTime.now();
    final perPhoto = _effectivePerPhoto;
    final clips = [
      for (final photo in _photos)
        VideoClip.fromMedia(
          id: newId(),
          sourcePath: photo.relativePath,
          media: photo.info,
          stillDuration: perPhoto,
        ).copyWith(
          transition: ClipTransition(type: _transition, duration: _transitionLength),
        ),
    ];
    var project = Project(
      id: newId(),
      name: 'Slideshow ${Formatters.date(now)}',
      createdAt: now,
      updatedAt: now,
      clips: clips,
      canvas: _canvas,
      exportSettings: ref.read(settingsProvider).defaultExport,
    );
    final music = _music;
    if (music != null) {
      final length = ProjectTimeline(project).duration;
      project = project.copyWith(
        audioTracks: [
          AudioTrack(
            id: newId(),
            name: p.basenameWithoutExtension(music.displayName),
            sourcePath: music.relativePath,
            media: music.info,
            start: Duration.zero,
            trimStart: Duration.zero,
            trimEnd: music.info.duration < length ? music.info.duration : length,
          ),
        ],
      );
    }
    return project;
  }

  Future<void> _addPhotos() async {
    final more = await importPhotos(context, ref);
    if (more.isNotEmpty) setState(() => _photos.addAll(more));
  }

  Future<void> _pickMusic() async {
    final audio = await importAudio(context, ref);
    if (audio.isNotEmpty) setState(() => _music = audio.first);
  }

  Future<void> _create() async {
    setState(() => _creating = true);
    try {
      final project = _buildProject();
      await ref.read(projectRepositoryProvider).save(project);
      await ref.read(projectsProvider.notifier).refresh();
      if (!mounted) return;
      await Navigator.of(context)
          .pushReplacement(MaterialPageRoute(builder: (_) => EditorScreen(project: project)));
    } catch (e) {
      if (mounted) {
        setState(() => _creating = false);
        await showAppError(context, e);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final paths = ref.read(mediaRepositoryProvider);
    final total = _photos.isEmpty ? Duration.zero : ProjectTimeline(_buildProject()).duration;
    final music = _music;

    return Scaffold(
      appBar: AppBar(title: const Text('Photo slideshow')),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Row(
                    children: [
                      Text(
                        '${_photos.length} photos',
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      const Spacer(),
                      TextButton.icon(
                        onPressed: _addPhotos,
                        icon: const Icon(Icons.add_photo_alternate_outlined),
                        label: const Text('Add photos'),
                      ),
                    ],
                  ),
                  Text(
                    'Long-press and drag to change the order.',
                    style: TextStyle(fontSize: 12, color: context.mutedColor),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    height: 116,
                    child: ReorderableListView.builder(
                      scrollDirection: Axis.horizontal,
                      itemCount: _photos.length,
                      onReorderItem: (oldIndex, newIndex) => setState(() {
                        _photos.insert(newIndex, _photos.removeAt(oldIndex));
                      }),
                      itemBuilder: (context, i) {
                        final photo = _photos[i];
                        return Padding(
                          key: ValueKey('${photo.relativePath}#$i'),
                          padding: const EdgeInsets.only(right: 8),
                          child: _PhotoTile(
                            path: paths.resolve(photo.relativePath),
                            number: i + 1,
                            onRemove: () => setState(() => _photos.removeAt(i)),
                          ),
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 20),
                  const _Label('Music'),
                  Card(
                    child: ListTile(
                      leading: Icon(
                        music == null ? Icons.library_music_outlined : Icons.music_note,
                        color: AppColors.audioTrack,
                      ),
                      title: Text(
                        music == null ? 'Add music' : p.basenameWithoutExtension(music.displayName),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        music == null
                            ? 'MP3, M4A, WAV or AAC from your files'
                            : Formatters.duration(music.info.duration),
                      ),
                      trailing: music == null
                          ? const Icon(Icons.chevron_right)
                          : IconButton(
                              tooltip: 'Remove music',
                              icon: const Icon(Icons.close),
                              onPressed: () => setState(() {
                                _music = null;
                                _matchMusic = false;
                              }),
                            ),
                      onTap: _pickMusic,
                    ),
                  ),
                  if (music != null)
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Fit slideshow to the song'),
                      subtitle: Text(
                        _matchMusic
                            ? 'Each photo shows for ${(_effectivePerPhoto.inMilliseconds / 1000).toStringAsFixed(1)} s'
                            : 'Photos keep the duration below; music is cut to fit',
                      ),
                      value: _matchMusic,
                      onChanged: (v) => setState(() => _matchMusic = v),
                    ),
                  const SizedBox(height: 12),
                  if (!_matchMusic) ...[
                    const _Label('Each photo'),
                    ChipRow<Duration>(
                      values: _durations,
                      selected: _perPhoto,
                      label: (d) => '${d.inSeconds} s',
                      onSelected: (d) => setState(() => _perPhoto = d),
                    ),
                    const SizedBox(height: 16),
                  ],
                  const _Label('Transition'),
                  ChipRow<TransitionType>(
                    values: TransitionType.values,
                    selected: _transition,
                    label: (t) => t.label,
                    onSelected: (t) => setState(() => _transition = t),
                  ),
                  const SizedBox(height: 16),
                  const _Label('Shape'),
                  ChipRow<AspectRatioPreset>(
                    values: _aspects,
                    selected: _canvas.aspectRatio,
                    label: (a) => a.label,
                    onSelected: (a) => setState(() => _canvas = _canvas.copyWith(aspectRatio: a)),
                  ),
                  const SizedBox(height: 10),
                  SegmentedButton<CanvasFit>(
                    segments: const [
                      ButtonSegment(value: CanvasFit.fill, label: Text('Fill frame')),
                      ButtonSegment(value: CanvasFit.fit, label: Text('Show whole photo')),
                    ],
                    selected: {_canvas.fit},
                    onSelectionChanged: (v) =>
                        setState(() => _canvas = _canvas.copyWith(fit: v.first)),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: Column(
                children: [
                  Text(
                    'Video length: ${Formatters.duration(total)}',
                    style: TextStyle(color: context.mutedColor),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: _photos.isEmpty || _creating ? null : _create,
                      icon: _creating
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.movie_creation_outlined),
                      label: const Text('Create video'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Label extends StatelessWidget {
  const _Label(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(text, style: const TextStyle(fontWeight: FontWeight.w600)),
  );
}

class _PhotoTile extends StatelessWidget {
  const _PhotoTile({required this.path, required this.number, required this.onRemove});
  final String path;
  final int number;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 88,
    child: Stack(
      children: [
        Positioned.fill(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Image.file(File(path), fit: BoxFit.cover, cacheWidth: 240),
          ),
        ),
        Positioned(
          left: 4,
          bottom: 4,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            decoration: BoxDecoration(
              color: Colors.black54,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text('$number', style: const TextStyle(fontSize: 11, color: Colors.white)),
          ),
        ),
        Positioned(
          right: 0,
          top: 0,
          child: IconButton(
            visualDensity: VisualDensity.compact,
            style: IconButton.styleFrom(backgroundColor: Colors.black54),
            iconSize: 16,
            color: Colors.white,
            tooltip: 'Remove',
            onPressed: onRemove,
            icon: const Icon(Icons.close),
          ),
        ),
      ],
    ),
  );
}
