import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../app/providers.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/formatters.dart';
import '../../domain/entities/audio_edit.dart';
import '../../domain/repositories/media_repository.dart';
import '../../services/video/video_processing_service.dart';
import '../editor/panels/panel_common.dart';
import 'audio_widgets.dart';

/// The one-file audio tools that only differ in their options.
enum AudioTool {
  extract('Video to audio', 'audio'),
  convert('Convert audio', 'converted'),
  compress('Compress audio', 'compressed'),
  clean('Clean audio', 'clean'),
  volume('Volume & speed', 'edited');

  const AudioTool(this.title, this.suffix);
  final String title;
  final String suffix;
}

class AudioToolScreen extends ConsumerStatefulWidget {
  const AudioToolScreen({super.key, required this.tool, required this.media});
  final AudioTool tool;
  final ImportedMedia media;

  @override
  ConsumerState<AudioToolScreen> createState() => _AudioToolScreenState();
}

class _AudioToolScreenState extends ConsumerState<AudioToolScreen> {
  final _player = AudioPreviewPlayer();
  late final String _path = ref.read(mediaRepositoryProvider).resolve(widget.media.relativePath);
  Duration get _duration => widget.media.info.duration;

  AudioOutputFormat _format = AudioOutputFormat.mp3;
  AudioQuality _quality = AudioQuality.kbps192;
  AudioCompression _compression = AudioCompression.medium;
  CleanupMode _cleanup = CleanupMode.backgroundNoise;
  NoiseStrength _strength = NoiseStrength.medium;
  double _volume = 1;
  bool _normalize = false;
  double _speed = 1;
  double _fadeIn = 0;
  double _fadeOut = 0;
  bool _busy = false;

  bool get _isVideo => widget.media.info.hasVideo && !widget.media.info.isStillImage;

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  AudioJob _job() {
    final source = AudioSource(_path, _duration);
    Duration ms(double s) => Duration(milliseconds: (s * 1000).round());
    return switch (widget.tool) {
      AudioTool.extract || AudioTool.convert => AudioJob.single(
        source: source,
        format: _format,
        quality: _quality,
      ),
      AudioTool.compress => AudioJob.single(
        source: source,
        format: AudioOutputFormat.mp3,
        quality: _compression.quality,
        mono: _compression.mono,
      ),
      AudioTool.clean => AudioJob.single(
        source: source,
        cleanup: CleanupSettings(_cleanup, _strength),
        format: _format,
        quality: _quality,
      ),
      AudioTool.volume => AudioJob.single(
        source: source,
        volume: _volume,
        normalize: _normalize,
        speed: _speed,
        fadeIn: ms(_fadeIn),
        fadeOut: ms(_fadeOut),
        format: _format,
        quality: _quality,
      ),
    };
  }

  @override
  Widget build(BuildContext context) {
    final info = widget.media.info;
    return Scaffold(
      appBar: AppBar(title: Text(widget.tool.title)),
      body: AbsorbPointer(
        absorbing: _busy,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            AudioFileCard(
              name: widget.media.displayName,
              duration: _duration,
              icon: _isVideo ? Icons.movie_outlined : Icons.music_note_rounded,
              subtitle: [
                Formatters.duration(_duration),
                if (info.audioCodec != null) info.audioCodec!.toUpperCase(),
                if (info.fileSize > 0) Formatters.fileSize(info.fileSize),
              ].join(' · '),
              trailing: PreviewButton(player: _player, path: _path),
            ),
            if (widget.tool != AudioTool.extract && widget.tool != AudioTool.convert)
              WaveformPadding(child: WaveformView(path: _path, duration: _duration, height: 64)),
            ..._options(context),
          ],
        ),
      ),
      bottomNavigationBar: AudioRunBar(
        label: switch (widget.tool) {
          AudioTool.extract => 'Extract audio',
          AudioTool.convert => 'Convert',
          AudioTool.compress => 'Compress',
          AudioTool.clean => 'Clean audio',
          AudioTool.volume => 'Save audio',
        },
        icon: switch (widget.tool) {
          AudioTool.extract => Icons.audiotrack_rounded,
          AudioTool.convert => Icons.swap_horiz_rounded,
          AudioTool.compress => Icons.compress_rounded,
          AudioTool.clean => Icons.auto_fix_high_rounded,
          AudioTool.volume => Icons.save_alt_rounded,
        },
        onBusyChanged: (b) => setState(() => _busy = b),
        baseName: () => '${p.basenameWithoutExtension(widget.media.displayName)}_${widget.tool.suffix}',
        buildJob: _job,
      ),
    );
  }

  List<Widget> _options(BuildContext context) {
    final output = OutputOptions(
      format: _format,
      quality: _quality,
      onFormat: (f) => setState(() => _format = f),
      onQuality: (q) => setState(() => _quality = q),
    );
    switch (widget.tool) {
      case AudioTool.extract:
      case AudioTool.convert:
        return [output];
      case AudioTool.compress:
        final size = widget.media.info.fileSize;
        return [
          const OptionLabel('Compression'),
          for (final c in AudioCompression.values)
            _ChoiceTile(
              selected: c == _compression,
              title: c.label,
              subtitle: '${c.hint} · ${c.kbps} kbps MP3',
              trailing: '≈ ${Formatters.fileSize(c.estimatedBytes(_duration))}',
              onTap: () => setState(() => _compression = c),
            ),
          if (size > 0)
            OptionHint(
              'Original ${Formatters.fileSize(size)}. '
              'Saved as MP3 so it plays on every phone.',
            ),
        ];
      case AudioTool.clean:
        return [
          const OptionLabel('Remove'),
          for (final m in CleanupMode.values)
            _ChoiceTile(
              selected: m == _cleanup,
              title: m.label,
              subtitle: m.hint,
              onTap: () => setState(() => _cleanup = m),
            ),
          if (_cleanup.hasStrength) ...[
            const OptionLabel('Strength'),
            ChipRow<NoiseStrength>(
              values: NoiseStrength.values,
              selected: _strength,
              label: (s) => s.label,
              onSelected: (s) => setState(() => _strength = s),
            ),
            const OptionHint('Start with Medium; Strong can make voices sound thin.'),
          ] else
            const OptionHint('Works on stereo songs where the singer is in the centre. '
                'Mono recordings become silent.'),
          output,
        ];
      case AudioTool.volume:
        final maxFade = (_duration.inMilliseconds / _speed / 2000).clamp(0.0, 10.0);
        return [
          const OptionLabel('Volume'),
          ValueSlider(
            label: 'Level',
            value: _volume,
            min: 0,
            max: 3,
            divisions: 30,
            onChanged: (v) => setState(() => _volume = v),
            format: formatPercent,
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Even out loudness', style: TextStyle(fontSize: 14)),
            subtitle: Text('Makes quiet parts louder and loud parts safer',
                style: TextStyle(fontSize: 12, color: context.mutedColor)),
            value: _normalize,
            onChanged: (v) => setState(() => _normalize = v),
          ),
          const OptionLabel('Speed'),
          ChipRow<double>(
            values: audioSpeeds,
            selected: _speed,
            label: Formatters.speed,
            onSelected: (v) => setState(() => _speed = v),
          ),
          const OptionHint('Voice pitch stays natural.'),
          const OptionLabel('Fades'),
          ValueSlider(
            label: 'Fade in',
            value: _fadeIn.clamp(0, maxFade),
            min: 0,
            max: maxFade <= 0 ? 1 : maxFade,
            onChanged: (v) => setState(() => _fadeIn = v),
            format: formatSeconds,
          ),
          ValueSlider(
            label: 'Fade out',
            value: _fadeOut.clamp(0, maxFade),
            min: 0,
            max: maxFade <= 0 ? 1 : maxFade,
            onChanged: (v) => setState(() => _fadeOut = v),
            format: formatSeconds,
          ),
          output,
        ];
    }
  }
}

class WaveformPadding extends StatelessWidget {
  const WaveformPadding({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) =>
      Padding(padding: const EdgeInsets.only(top: 12), child: child);
}

/// A selectable option row (radio-like).
class _ChoiceTile extends StatelessWidget {
  const _ChoiceTile({
    required this.selected,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.trailing,
  });

  final bool selected;
  final String title;
  final String subtitle;
  final String? trailing;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: selected ? scheme.primary.withValues(alpha: 0.08) : scheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(
            color: selected ? scheme.primary : scheme.outlineVariant.withValues(alpha: 0.6),
            width: selected ? 1.5 : 1,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 14, 10),
            child: Row(
              children: [
                Icon(
                  selected ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded,
                  color: selected ? scheme.primary : context.mutedColor,
                  size: 20,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                      Text(subtitle, style: TextStyle(fontSize: 12, color: context.mutedColor)),
                    ],
                  ),
                ),
                if (trailing != null)
                  Text(trailing!, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
