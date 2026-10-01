import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../app/providers.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/formatters.dart';
import '../../domain/entities/audio_edit.dart';
import '../../domain/repositories/media_repository.dart';
import '../../services/video/video_processing_service.dart';
import 'audio_widgets.dart';

/// Keep or remove a part of a song/recording, with fades (ringtones,
/// intros, cutting out a section).
class AudioCutScreen extends ConsumerStatefulWidget {
  const AudioCutScreen({super.key, required this.media});
  final ImportedMedia media;

  @override
  ConsumerState<AudioCutScreen> createState() => _AudioCutScreenState();
}

class _AudioCutScreenState extends ConsumerState<AudioCutScreen> {
  final _player = AudioPreviewPlayer();
  late final String _path = ref.read(mediaRepositoryProvider).resolve(widget.media.relativePath);
  late final Duration _total = widget.media.info.duration;
  late Duration _start = Duration.zero;
  late Duration _end = _total;
  bool _remove = false;
  double _fadeIn = 0;
  double _fadeOut = 0;
  AudioOutputFormat _format = AudioOutputFormat.mp3;
  AudioQuality _quality = AudioQuality.kbps192;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    // Start with a sensible selection: the middle half.
    if (_total > const Duration(seconds: 8)) {
      _start = _total ~/ 4;
      _end = _total * 3 ~/ 4;
    }
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  Duration get _resultLength => _remove ? _total - (_end - _start) : _end - _start;

  void _nudge({required bool start, required int ms}) {
    const minGap = Duration(milliseconds: 200);
    setState(() {
      if (start) {
        final v = _start + Duration(milliseconds: ms);
        _start = v.isNegative ? Duration.zero : (v > _end - minGap ? _end - minGap : v);
      } else {
        final v = _end + Duration(milliseconds: ms);
        _end = v > _total ? _total : (v < _start + minGap ? _start + minGap : v);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final maxFade = (_resultLength.inMilliseconds / 2000).clamp(0.0, 10.0);
    return Scaffold(
      appBar: AppBar(title: const Text('Cut audio')),
      body: AbsorbPointer(
        absorbing: _busy,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            AudioFileCard(
              name: widget.media.displayName,
              duration: _total,
              trailing: PreviewButton(player: _player, path: _path),
            ),
            const OptionLabel('Select the part'),
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: false, icon: Icon(Icons.crop_rounded), label: Text('Keep part')),
                ButtonSegment(value: true, icon: Icon(Icons.content_cut_rounded), label: Text('Remove part')),
              ],
              selected: {_remove},
              onSelectionChanged: (v) => setState(() => _remove = v.first),
            ),
            const SizedBox(height: 14),
            ListenableBuilder(
              listenable: _player,
              builder: (context, _) => WaveformView(
                path: _path,
                duration: _total,
                selectionStart: _start,
                selectionEnd: _end,
                removeSelection: _remove,
                position: _player.isPlaying ? _player.position : null,
                onSelectionChanged: (s, e) => setState(() {
                  _start = s;
                  _end = e;
                }),
                height: 110,
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(child: _TimeBox(label: 'Start', value: _start, onNudge: (ms) => _nudge(start: true, ms: ms))),
                const SizedBox(width: 10),
                Expanded(child: _TimeBox(label: 'End', value: _end, onNudge: (ms) => _nudge(start: false, ms: ms))),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                PreviewButton(
                  player: _player,
                  path: _path,
                  from: _remove ? Duration.zero : _start,
                  until: _remove ? null : _end,
                ),
                Text(_remove ? 'Play original' : 'Play selection'),
                const Spacer(),
                Text(
                  'Result ${Formatters.duration(_resultLength, showTenths: true)}',
                  style: TextStyle(color: context.mutedColor, fontSize: 12.5),
                ),
              ],
            ),
            const OptionLabel('Fades'),
            ValueSlider(
              label: 'Fade in',
              value: _fadeIn.clamp(0, maxFade),
              min: 0,
              max: maxFade <= 0 ? 1 : maxFade,
              onChanged: maxFade <= 0 ? (_) {} : (v) => setState(() => _fadeIn = v),
              format: formatSeconds,
            ),
            ValueSlider(
              label: 'Fade out',
              value: _fadeOut.clamp(0, maxFade),
              min: 0,
              max: maxFade <= 0 ? 1 : maxFade,
              onChanged: maxFade <= 0 ? (_) {} : (v) => setState(() => _fadeOut = v),
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
      bottomNavigationBar: AudioRunBar(
        label: 'Save audio',
        icon: Icons.save_alt_rounded,
        onBusyChanged: (b) => setState(() => _busy = b),
        baseName: () => '${p.basenameWithoutExtension(widget.media.displayName)}_cut',
        buildJob: () => AudioJob.single(
          source: AudioSource(_path, _total),
          selectionStart: _start,
          selectionEnd: _end,
          removeSelection: _remove,
          fadeIn: Duration(milliseconds: (_fadeIn * 1000).round()),
          fadeOut: Duration(milliseconds: (_fadeOut * 1000).round()),
          format: _format,
          quality: _quality,
        ),
      ),
    );
  }
}

/// Time readout with fine ±0.1 s nudges.
class _TimeBox extends StatelessWidget {
  const _TimeBox({required this.label, required this.value, required this.onNudge});
  final String label;
  final Duration value;
  final ValueChanged<int> onNudge;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        color: scheme.primary.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: '-0.1 s',
            onPressed: () => onNudge(-100),
            icon: const Icon(Icons.remove_rounded, size: 18),
          ),
          Expanded(
            child: Column(
              children: [
                Text(label, style: TextStyle(fontSize: 11, color: context.mutedColor)),
                Text(
                  Formatters.duration(value, showTenths: true),
                  style: const TextStyle(fontWeight: FontWeight.w600, fontFeatures: [FontFeature.tabularFigures()]),
                ),
              ],
            ),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: '+0.1 s',
            onPressed: () => onNudge(100),
            icon: const Icon(Icons.add_rounded, size: 18),
          ),
        ],
      ),
    );
  }
}
