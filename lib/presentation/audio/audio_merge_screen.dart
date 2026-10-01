import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/formatters.dart';
import '../../domain/entities/audio_edit.dart';
import '../../domain/repositories/media_repository.dart';
import '../../services/video/video_processing_service.dart';
import '../widgets/app_dialogs.dart';
import '../widgets/media_import_flow.dart';
import 'audio_widgets.dart';

/// Joins songs/recordings one after another, optionally cross-faded.
class AudioMergeScreen extends ConsumerStatefulWidget {
  const AudioMergeScreen({super.key, required this.initial});
  final List<ImportedMedia> initial;

  @override
  ConsumerState<AudioMergeScreen> createState() => _AudioMergeScreenState();
}

class _AudioMergeScreenState extends ConsumerState<AudioMergeScreen> {
  late final List<ImportedMedia> _items = [...widget.initial];
  final _player = AudioPreviewPlayer();
  double _crossfade = 0;
  double _fadeOut = 0;
  AudioOutputFormat _format = AudioOutputFormat.mp3;
  AudioQuality _quality = AudioQuality.kbps192;
  bool _busy = false;

  String _abs(ImportedMedia m) => ref.read(mediaRepositoryProvider).resolve(m.relativePath);

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    final more = await importAudio(context, ref, multiple: true);
    if (more.isNotEmpty && mounted) setState(() => _items.addAll(more));
  }

  AudioJob? _job() {
    if (_items.length < 2) {
      showSnack(context, 'Add at least two audio files to merge.');
      return null;
    }
    return AudioJob.merge(
      sources: [for (final m in _items) AudioSource(_abs(m), m.info.duration)],
      crossfade: Duration(milliseconds: (_crossfade * 1000).round()),
      fadeOut: Duration(milliseconds: (_fadeOut * 1000).round()),
      format: _format,
      quality: _quality,
    );
  }

  @override
  Widget build(BuildContext context) {
    var total = Duration.zero;
    for (final m in _items) {
      total += m.info.duration;
    }
    final xf = Duration(milliseconds: (_crossfade * 1000).round());
    if (_items.length > 1) total -= xf * (_items.length - 1);

    return Scaffold(
      appBar: AppBar(title: const Text('Merge audio')),
      body: AbsorbPointer(
        absorbing: _busy,
        child: CustomScrollView(
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              sliver: SliverToBoxAdapter(
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${_items.length} files · ${Formatters.duration(total)}',
                        style: TextStyle(color: context.mutedColor, fontSize: 12.5),
                      ),
                    ),
                    Text('Drag to reorder', style: TextStyle(color: context.mutedColor, fontSize: 12)),
                  ],
                ),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              sliver: SliverReorderableList(
                itemCount: _items.length,
                onReorderItem: (from, to) => setState(() {
                  _items.insert(to, _items.removeAt(from));
                }),
                itemBuilder: (context, i) {
                  final m = _items[i];
                  return Padding(
                    key: ValueKey('${m.relativePath}#$i'),
                    padding: const EdgeInsets.only(bottom: 8),
                    child: AudioFileCard(
                      name: '${i + 1}. ${m.displayName}',
                      duration: m.info.duration,
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          PreviewButton(player: _player, path: _abs(m)),
                          IconButton(
                            tooltip: 'Remove',
                            onPressed: () => setState(() => _items.removeAt(i)),
                            icon: const Icon(Icons.close_rounded, size: 20),
                          ),
                          ReorderableDragStartListener(
                            index: i,
                            child: const Padding(
                              padding: EdgeInsets.all(6),
                              child: Icon(Icons.drag_handle_rounded),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
              sliver: SliverList.list(
                children: [
                  OutlinedButton.icon(
                    onPressed: _add,
                    icon: const Icon(Icons.add_rounded),
                    label: const Text('Add audio'),
                  ),
                  const OptionLabel('Transitions'),
                  ValueSlider(
                    label: 'Cross-fade',
                    value: _crossfade,
                    min: 0,
                    max: 5,
                    divisions: 10,
                    onChanged: (v) => setState(() => _crossfade = v),
                    format: formatSeconds,
                  ),
                  const OptionHint('Blends the end of each file into the next instead of a hard cut.'),
                  ValueSlider(
                    label: 'Fade out',
                    value: _fadeOut,
                    min: 0,
                    max: 10,
                    divisions: 20,
                    onChanged: (v) => setState(() => _fadeOut = v),
                    format: formatSeconds,
                  ),
                  OutputOptions(
                    format: _format,
                    quality: _quality,
                    onFormat: (f) => setState(() => _format = f),
                    onQuality: (q) => setState(() => _quality = q),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: AudioRunBar(
        label: 'Merge',
        icon: Icons.merge_type_rounded,
        onBusyChanged: (b) => setState(() => _busy = b),
        baseName: () => 'merged_audio',
        buildJob: _job,
      ),
    );
  }
}
