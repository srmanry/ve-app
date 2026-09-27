import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../../app/providers.dart';
import '../../core/errors/app_exception.dart';
import '../../core/utils/formatters.dart';
import '../../domain/entities/exported_media.dart';
import '../../domain/repositories/media_repository.dart';
import '../../services/export/export_service.dart';
import '../../services/video/video_processing_service.dart';
import '../editor/panels/panel_common.dart';
import '../exports/export_actions.dart';
import '../widgets/app_dialogs.dart';

/// Extracts the audio track of a video into M4A (AAC) or WAV.
class VideoToAudioScreen extends ConsumerStatefulWidget {
  const VideoToAudioScreen({super.key, required this.media});
  final ImportedMedia media;

  @override
  ConsumerState<VideoToAudioScreen> createState() => _VideoToAudioScreenState();
}

class _VideoToAudioScreenState extends ConsumerState<VideoToAudioScreen> {
  AudioOutputFormat _format = AudioOutputFormat.m4a;
  ExportJob? _job;
  double _progress = 0;
  ExportedMedia? _result;
  StreamSubscription<ExportProgress>? _sub;

  @override
  void dispose() {
    unawaited(_sub?.cancel());
    if (_job != null && _result == null) unawaited(_job!.cancel());
    super.dispose();
  }

  Future<void> _extract() async {
    final job = ref
        .read(exportServiceProvider)
        .exportAudio(
          sourceRelativePath: widget.media.relativePath,
          displayName: widget.media.displayName,
          format: _format,
          duration: widget.media.info.duration,
        );
    setState(() => _job = job);
    _sub = job.progress.listen((p) {
      if (mounted) setState(() => _progress = p.fraction);
    });
    try {
      final result = await job.result;
      await ref.read(exportsProvider.notifier).refresh();
      if (mounted) setState(() => _result = result);
    } catch (e) {
      if (!mounted) return;
      setState(() => _job = null);
      if (!AppException.from(e).isCancellation) await showAppError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final info = widget.media.info;
    final running = _job != null && _result == null;
    final actions = ExportActions(ref);
    return Scaffold(
      appBar: AppBar(title: const Text('Video to audio')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Card(
            child: ListTile(
              leading: const Icon(Icons.movie_outlined),
              title: Text(widget.media.displayName, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(
                '${Formatters.duration(info.duration)} · '
                'audio: ${info.audioCodec ?? 'unknown'}',
              ),
            ),
          ),
          const SizedBox(height: 20),
          if (_result == null) ...[
            const Text('Format', style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            ChipRow<AudioOutputFormat>(
              values: AudioOutputFormat.values,
              selected: _format,
              label: (f) => f.label,
              onSelected: running ? (_) {} : (f) => setState(() => _format = f),
            ),
            const SizedBox(height: 6),
            Text(
              _format == AudioOutputFormat.m4a
                  ? 'Small file, widely supported.'
                  : 'Uncompressed, best for further editing (large file).',
              style: TextStyle(fontSize: 12, color: context.mutedColor),
            ),
            const SizedBox(height: 28),
            if (running) ...[
              LinearProgressIndicator(value: _progress),
              const SizedBox(height: 8),
              Text('Extracting… ${(_progress * 100).floor()}%', textAlign: TextAlign.center),
              const SizedBox(height: 12),
              OutlinedButton(onPressed: () => _job?.cancel(), child: const Text('Cancel')),
            ] else
              FilledButton.icon(
                onPressed: _extract,
                icon: const Icon(Icons.audiotrack),
                label: const Text('Extract audio'),
              ),
          ] else ...[
            const Icon(Icons.check_circle, color: Colors.greenAccent, size: 48),
            const SizedBox(height: 8),
            Text(_result!.fileName, textAlign: TextAlign.center),
            Text(
              Formatters.fileSize(_result!.sizeBytes),
              textAlign: TextAlign.center,
              style: TextStyle(color: context.mutedColor),
            ),
            const SizedBox(height: 20),
            Wrap(
              alignment: WrapAlignment.center,
              children: [
                PanelAction(
                  icon: Icons.play_arrow,
                  label: 'Play',
                  onTap: () => actions.play(context, _result!),
                ),
                Builder(
                  builder: (context) => PanelAction(
                    icon: Icons.ios_share,
                    label: 'Share',
                    onTap: () => actions.share(context, _result!),
                  ),
                ),
                PanelAction(
                  icon: Icons.folder_open_outlined,
                  label: 'Location',
                  onTap: () => actions.openLocation(context, _result!),
                ),
              ],
            ),
            const SizedBox(height: 20),
            OutlinedButton(onPressed: () => Navigator.pop(context), child: const Text('Done')),
          ],
        ],
      ),
    );
  }
}
