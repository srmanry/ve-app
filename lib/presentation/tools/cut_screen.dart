import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:video_player/video_player.dart';

import '../../app/providers.dart';
import '../../core/constants/app_constants.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/formatters.dart';
import '../../core/utils/id_generator.dart';
import '../../domain/entities/project.dart';
import '../../domain/entities/video_clip.dart';
import '../../domain/repositories/media_repository.dart';
import '../editor/editor_screen.dart';
import '../export/export_screen.dart';
import '../widgets/app_dialogs.dart';

enum CutMode {
  keep('Keep selection', 'Only the selected part is kept'),
  remove('Remove selection', 'The selected part is cut out, the rest is joined');

  const CutMode(this.label, this.description);
  final String label;
  final String description;
}

/// Pick the part of a (long) video you need: scrub, mark start/end at the
/// playhead with frame-level nudges, preview, then export or keep editing.
class CutScreen extends ConsumerStatefulWidget {
  const CutScreen({super.key, required this.media});
  final ImportedMedia media;

  @override
  ConsumerState<CutScreen> createState() => _CutScreenState();
}

class _CutScreenState extends ConsumerState<CutScreen> {
  late final VideoPlayerController _player;
  late Duration _start = Duration.zero;
  late Duration _end = widget.media.info.duration;
  CutMode _mode = CutMode.keep;
  Duration? _stopAt;
  bool _ready = false;

  Duration get _total => widget.media.info.duration;
  static const _nudge = Duration(milliseconds: 100);

  @override
  void initState() {
    super.initState();
    _player = VideoPlayerController.file(
      File(ref.read(mediaRepositoryProvider).resolve(widget.media.relativePath)),
    )..addListener(_onTick);
    _player.initialize().then((_) {
      if (mounted) setState(() => _ready = true);
    });
  }

  @override
  void dispose() {
    _player
      ..removeListener(_onTick)
      ..dispose();
    super.dispose();
  }

  void _onTick() {
    final stop = _stopAt;
    if (stop != null && _player.value.isPlaying && _player.value.position >= stop) {
      unawaited(_player.pause());
      _stopAt = null;
    }
    if (mounted) setState(() {});
  }

  Duration get _position => _player.value.position;

  void _seek(Duration t) {
    final clamped = t < Duration.zero ? Duration.zero : (t > _total ? _total : t);
    unawaited(_player.seekTo(clamped));
  }

  void _setStart(Duration t) {
    final max = _end - AppConstants.minClipDuration;
    setState(() => _start = t < Duration.zero ? Duration.zero : (t > max ? max : t));
    _seek(_start);
  }

  void _setEnd(Duration t) {
    final min = _start + AppConstants.minClipDuration;
    setState(() => _end = t > _total ? _total : (t < min ? min : t));
    _seek(_end);
  }

  Future<void> _previewSelection() async {
    _stopAt = _end;
    await _player.seekTo(_start);
    await _player.play();
  }

  /// The resulting project: one clip (keep) or the two outer parts (remove).
  Project _buildProject() {
    final m = widget.media;
    VideoClip part(Duration s, Duration e) => VideoClip.fromMedia(
      id: newId(),
      sourcePath: m.relativePath,
      media: m.info,
    ).copyWith(trimStart: s, trimEnd: e);
    final min = AppConstants.minClipDuration;
    final clips = _mode == CutMode.keep
        ? [part(_start, _end)]
        : [
            if (_start >= min) part(Duration.zero, _start),
            if (_total - _end >= min) part(_end, _total),
          ];
    final now = DateTime.now();
    return Project(
      id: newId(),
      name: '${p.basenameWithoutExtension(m.displayName)}_cut',
      createdAt: now,
      updatedAt: now,
      clips: clips,
      exportSettings: ref.read(settingsProvider).defaultExport,
    );
  }

  Duration get _resultLength => _mode == CutMode.keep ? _end - _start : _total - (_end - _start);

  Future<void> _export() async {
    await _player.pause();
    final project = _buildProject();
    if (project.clips.isEmpty) {
      if (mounted) showSnack(context, 'Nothing would be left. Select a smaller part to remove.');
      return;
    }
    if (!mounted) return;
    await Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => ExportScreen(project: project)));
  }

  Future<void> _openInEditor() async {
    await _player.pause();
    final project = _buildProject();
    if (project.clips.isEmpty) {
      if (mounted) showSnack(context, 'Nothing would be left. Select a smaller part to remove.');
      return;
    }
    await ref.read(projectRepositoryProvider).save(project);
    await ref.read(projectsProvider.notifier).refresh();
    if (!mounted) return;
    await Navigator.of(context)
        .pushReplacement(MaterialPageRoute(builder: (_) => EditorScreen(project: project)));
  }

  @override
  Widget build(BuildContext context) {
    final totalMs = _total.inMilliseconds.toDouble();
    final pos = _position;
    return StudioTheme(
      child: Scaffold(
        appBar: AppBar(title: const Text('Cut video')),
        body: SafeArea(
          child: Column(
            children: [
              Expanded(
                child: Container(
                  color: Colors.black,
                  alignment: Alignment.center,
                  child: _ready
                      ? AspectRatio(
                          aspectRatio: _player.value.aspectRatio,
                          child: VideoPlayer(_player),
                        )
                      : const CircularProgressIndicator(),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                child: Row(
                  children: [
                    IconButton.filledTonal(
                      onPressed: !_ready
                          ? null
                          : () => _player.value.isPlaying ? _player.pause() : _player.play(),
                      icon: Icon(_player.value.isPlaying ? Icons.pause : Icons.play_arrow),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '${Formatters.duration(pos, showTenths: true)} / ${Formatters.duration(_total)}',
                      style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()]),
                    ),
                    const Spacer(),
                    TextButton.icon(
                      onPressed: _ready ? _previewSelection : null,
                      icon: const Icon(Icons.play_circle_outline),
                      label: const Text('Preview part'),
                    ),
                  ],
                ),
              ),
              // Playhead scrubber.
              Slider(
                value: pos.inMilliseconds.clamp(0, totalMs.toInt()).toDouble(),
                max: totalMs <= 0 ? 1 : totalMs,
                onChanged: (v) => _seek(Duration(milliseconds: v.round())),
              ),
              // Selection.
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: RangeSlider(
                  values: RangeValues(
                    _start.inMilliseconds.toDouble(),
                    _end.inMilliseconds.toDouble(),
                  ),
                  max: totalMs <= 0 ? 1 : totalMs,
                  onChanged: (v) {
                    final s = Duration(milliseconds: v.start.round());
                    final e = Duration(milliseconds: v.end.round());
                    if (e - s < AppConstants.minClipDuration) return;
                    final movedStart = s != _start;
                    setState(() {
                      _start = s;
                      _end = e;
                    });
                    _seek(movedStart ? s : e);
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    Expanded(
                      child: _MarkControl(
                        label: 'Start',
                        value: _start,
                        onSetHere: () => _setStart(pos),
                        onMinus: () => _setStart(_start - _nudge),
                        onPlus: () => _setStart(_start + _nudge),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _MarkControl(
                        label: 'End',
                        value: _end,
                        onSetHere: () => _setEnd(pos),
                        onMinus: () => _setEnd(_end - _nudge),
                        onPlus: () => _setEnd(_end + _nudge),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: SegmentedButton<CutMode>(
                  segments: [
                    for (final m in CutMode.values)
                      ButtonSegment(
                        value: m,
                        label: Text(m.label),
                        icon: Icon(
                          m == CutMode.keep ? Icons.content_cut : Icons.remove_circle_outline,
                        ),
                      ),
                  ],
                  selected: {_mode},
                  onSelectionChanged: (v) => setState(() => _mode = v.first),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Text(
                  '${_mode.description} · result ${Formatters.duration(_resultLength, showTenths: true)}',
                  style: TextStyle(fontSize: 12, color: context.mutedColor),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: _openInEditor,
                        child: const Text('Open in editor'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton(onPressed: _export, child: const Text('Export')),
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

class _MarkControl extends StatelessWidget {
  const _MarkControl({
    required this.label,
    required this.value,
    required this.onSetHere,
    required this.onMinus,
    required this.onPlus,
  });

  final String label;
  final Duration value;
  final VoidCallback onSetHere;
  final VoidCallback onMinus;
  final VoidCallback onPlus;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(8),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(12),
    ),
    child: Column(
      children: [
        Text(
          '$label  ${Formatters.duration(value, showTenths: true)}',
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            IconButton(
              visualDensity: VisualDensity.compact,
              tooltip: '−0.1 s',
              onPressed: onMinus,
              icon: const Icon(Icons.remove),
            ),
            TextButton(onPressed: onSetHere, child: const Text('Set here')),
            IconButton(
              visualDensity: VisualDensity.compact,
              tooltip: '+0.1 s',
              onPressed: onPlus,
              icon: const Icon(Icons.add),
            ),
          ],
        ),
      ],
    ),
  );
}
