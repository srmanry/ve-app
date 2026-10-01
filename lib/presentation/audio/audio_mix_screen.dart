import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/formatters.dart';
import '../../domain/entities/audio_edit.dart';
import '../../domain/repositories/media_repository.dart';
import '../../services/video/video_processing_service.dart';
import '../editor/panels/panel_common.dart';
import '../widgets/app_dialogs.dart';
import '../widgets/media_import_flow.dart';
import 'audio_widgets.dart';

/// Layers several tracks (voice over music, background under a song…) or,
/// with [arrange], places clips one after another on a timeline with gaps.
/// Every track has its own volume, trim and volume shape.
class AudioMixScreen extends ConsumerStatefulWidget {
  const AudioMixScreen({super.key, required this.initial, this.arrange = false});
  final List<ImportedMedia> initial;
  final bool arrange;

  @override
  ConsumerState<AudioMixScreen> createState() => _AudioMixScreenState();
}

class _Entry {
  _Entry(this.id, this.track);
  final int id;
  MixTrack track;
}

class _AudioMixScreenState extends ConsumerState<AudioMixScreen> {
  final _player = AudioPreviewPlayer();
  final List<_Entry> _entries = [];
  int _nextId = 0;
  MixLength _length = MixLength.main;
  bool _loop = false;
  double _gap = 0;
  AudioOutputFormat _format = AudioOutputFormat.mp3;
  AudioQuality _quality = AudioQuality.kbps192;
  bool _busy = false;

  bool get _arrange => widget.arrange;

  @override
  void initState() {
    super.initState();
    _addMedia(widget.initial);
    // A background layer is usually quieter than the main track.
    if (!_arrange) {
      for (final e in _entries.skip(1)) {
        e.track = e.track.copyWith(volume: 0.5);
      }
    }
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  void _addMedia(List<ImportedMedia> media) {
    final repo = ref.read(mediaRepositoryProvider);
    for (final m in media) {
      _entries.add(
        _Entry(
          _nextId++,
          MixTrack(
            path: repo.resolve(m.relativePath),
            name: m.displayName,
            sourceDuration: m.info.duration,
            volume: _entries.isEmpty || _arrange ? 1 : 0.5,
          ),
        ),
      );
    }
  }

  Future<void> _add() async {
    final more = await importAudio(context, ref, multiple: true);
    if (more.isNotEmpty && mounted) setState(() => _addMedia(more));
  }

  /// Tracks with arrange-mode starts applied.
  List<MixTrack> get _tracks {
    if (!_arrange) return [for (final e in _entries) e.track];
    final out = <MixTrack>[];
    var at = Duration.zero;
    final gap = Duration(milliseconds: (_gap * 1000).round());
    for (final e in _entries) {
      final t = e.track.copyWith(start: at);
      out.add(t);
      at = t.end + gap;
    }
    return out;
  }

  Duration get _mixDuration {
    final tracks = _tracks;
    if (tracks.isEmpty) return Duration.zero;
    if (!_arrange && _length == MixLength.main) return tracks.first.end;
    return tracks.map((t) => t.end).reduce((a, b) => a > b ? a : b);
  }

  AudioJob? _job() {
    if (_entries.length < (_arrange ? 1 : 2)) {
      showSnack(context, _arrange ? 'Add some audio first.' : 'Add at least two tracks to mix.');
      return null;
    }
    return AudioJob.mix(
      tracks: _tracks,
      mixLength: _arrange ? MixLength.longest : _length,
      loopShorter: !_arrange && _loop,
      format: _format,
      quality: _quality,
    );
  }

  void _update(_Entry e, MixTrack t) => setState(() => e.track = t);

  @override
  Widget build(BuildContext context) {
    final tracks = _tracks;
    final total = _mixDuration;
    return Scaffold(
      appBar: AppBar(title: Text(_arrange ? 'Arrange audio' : 'Mix audio')),
      body: AbsorbPointer(
        absorbing: _busy,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            _MixTimeline(tracks: tracks, total: total, loopFrom: !_arrange && _loop ? 1 : null),
            Padding(
              padding: const EdgeInsets.only(top: 6, bottom: 4),
              child: Text(
                '${tracks.length} tracks · result ${Formatters.duration(total)}',
                style: TextStyle(fontSize: 12.5, color: context.mutedColor),
              ),
            ),
            for (var i = 0; i < _entries.length; i++)
              _TrackCard(
                key: ValueKey(_entries[i].id),
                index: i,
                track: tracks[i],
                isMain: !_arrange && i == 0,
                arrange: _arrange,
                timelineMax: math.max(total.inMilliseconds, tracks[i].sourceDuration.inMilliseconds),
                player: _player,
                onChanged: (t) => _update(_entries[i], _arrange ? t.copyWith(start: Duration.zero) : t),
                onRemove: () => setState(() => _entries.removeAt(i)),
                onMoveUp: i == 0 ? null : () => setState(() => _entries.insert(i - 1, _entries.removeAt(i))),
                onMoveDown: i == _entries.length - 1
                    ? null
                    : () => setState(() => _entries.insert(i + 1, _entries.removeAt(i))),
              ),
            const SizedBox(height: 4),
            OutlinedButton.icon(
              onPressed: _add,
              icon: const Icon(Icons.add_rounded),
              label: Text(_arrange ? 'Add clip' : 'Add track'),
            ),
            if (_arrange) ...[
              const OptionLabel('Spacing'),
              ValueSlider(
                label: 'Gap',
                value: _gap,
                min: 0,
                max: 10,
                divisions: 20,
                onChanged: (v) => setState(() => _gap = v),
                format: formatSeconds,
              ),
              const OptionHint('Silence between clips. Use the arrows to change the order.'),
            ] else ...[
              const OptionLabel('Length'),
              ChipRow<MixLength>(
                values: MixLength.values,
                selected: _length,
                label: (l) => l.label,
                onSelected: (l) => setState(() => _length = l),
              ),
              if (_length == MixLength.main)
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Loop shorter tracks', style: TextStyle(fontSize: 14)),
                  subtitle: Text('Repeat background music until the main track ends',
                      style: TextStyle(fontSize: 12, color: context.mutedColor)),
                  value: _loop,
                  onChanged: (v) => setState(() => _loop = v),
                ),
            ],
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
        label: _arrange ? 'Save' : 'Mix',
        icon: _arrange ? Icons.save_alt_rounded : Icons.layers_rounded,
        onBusyChanged: (b) => setState(() => _busy = b),
        baseName: () => _arrange ? 'arranged_audio' : 'mixed_audio',
        buildJob: _job,
      ),
    );
  }
}

/// Overview: one bar per track on the shared timeline.
class _MixTimeline extends StatelessWidget {
  const _MixTimeline({required this.tracks, required this.total, this.loopFrom});
  final List<MixTrack> tracks;
  final Duration total;
  final int? loopFrom;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final totalMs = math.max(1, total.inMilliseconds);
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: scheme.primary.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(14),
      ),
      child: LayoutBuilder(
        builder: (context, box) => Column(
          children: [
            for (var i = 0; i < tracks.length; i++)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: SizedBox(
                  height: 16,
                  child: Stack(
                    children: [
                      Positioned(
                        left: box.maxWidth * (tracks[i].start.inMilliseconds / totalMs).clamp(0.0, 1.0),
                        width: box.maxWidth *
                            (loopFrom != null && i >= loopFrom!
                                    ? 1.0 - tracks[i].start.inMilliseconds / totalMs
                                    : tracks[i].usedLength.inMilliseconds / totalMs)
                                .clamp(0.01, 1.0),
                        top: 0,
                        bottom: 0,
                        child: Container(
                          decoration: BoxDecoration(
                            color: scheme.primary.withValues(alpha: i == 0 ? 0.85 : 0.45),
                            borderRadius: BorderRadius.circular(5),
                          ),
                          padding: const EdgeInsets.symmetric(horizontal: 6),
                          alignment: Alignment.centerLeft,
                          child: Text(
                            '${i + 1}',
                            style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w700),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _TrackCard extends StatelessWidget {
  const _TrackCard({
    super.key,
    required this.index,
    required this.track,
    required this.isMain,
    required this.arrange,
    required this.timelineMax,
    required this.player,
    required this.onChanged,
    required this.onRemove,
    required this.onMoveUp,
    required this.onMoveDown,
  });

  final int index;
  final MixTrack track;
  final bool isMain;
  final bool arrange;
  final int timelineMax;
  final AudioPreviewPlayer player;
  final ValueChanged<MixTrack> onChanged;
  final VoidCallback onRemove;
  final VoidCallback? onMoveUp;
  final VoidCallback? onMoveDown;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final srcMs = math.max(1, track.sourceDuration.inMilliseconds).toDouble();
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      clipBehavior: Clip.antiAlias,
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          initiallyExpanded: index < 2,
          tilePadding: const EdgeInsets.fromLTRB(12, 0, 4, 0),
          childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
          leading: CircleAvatar(
            radius: 15,
            backgroundColor: scheme.primary.withValues(alpha: isMain ? 1 : 0.12),
            child: Text(
              '${index + 1}',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: isMain ? Colors.white : scheme.primary,
              ),
            ),
          ),
          title: Text(track.name, maxLines: 1, overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
          subtitle: Text(
            [
              if (isMain) 'Main',
              Formatters.duration(track.usedLength),
              if (!arrange && track.start > Duration.zero) 'starts ${Formatters.duration(track.start)}',
              formatPercent(track.volume),
            ].join(' · '),
            style: TextStyle(fontSize: 11.5, color: context.mutedColor),
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              PreviewButton(player: player, path: track.path, from: track.trimStart, until: track.usedEnd),
              PopupMenuButton<String>(
                onSelected: (v) => switch (v) {
                  'up' => onMoveUp?.call(),
                  'down' => onMoveDown?.call(),
                  _ => onRemove(),
                },
                itemBuilder: (_) => [
                  if (onMoveUp != null)
                    PopupMenuItem(value: 'up', child: Text(arrange ? 'Move earlier' : 'Move up (make main)')),
                  if (onMoveDown != null)
                    PopupMenuItem(value: 'down', child: Text(arrange ? 'Move later' : 'Move down')),
                  const PopupMenuItem(value: 'remove', child: Text('Remove')),
                ],
              ),
            ],
          ),
          children: [
            ValueSlider(
              label: 'Volume',
              value: track.volume,
              min: 0,
              max: 2,
              divisions: 40,
              onChanged: (v) => onChanged(track.copyWith(volume: v)),
              format: formatPercent,
            ),
            if (!arrange)
              ValueSlider(
                label: 'Starts at',
                value: track.start.inMilliseconds / 1000,
                min: 0,
                max: timelineMax / 1000,
                onChanged: (v) => onChanged(track.copyWith(start: Duration(milliseconds: (v * 1000).round()))),
                format: (v) => Formatters.duration(Duration(milliseconds: (v * 1000).round())),
              ),
            Row(
              children: [
                const SizedBox(width: 86, child: Text('Use part', style: TextStyle(fontSize: 13))),
                Expanded(
                  child: RangeSlider(
                    values: RangeValues(
                      track.trimStart.inMilliseconds.toDouble().clamp(0, srcMs),
                      track.usedEnd.inMilliseconds.toDouble().clamp(0, srcMs),
                    ),
                    min: 0,
                    max: srcMs,
                    onChanged: (r) {
                      if (r.end - r.start < 300) return;
                      onChanged(track.copyWith(
                        trimStart: Duration(milliseconds: r.start.round()),
                        trimEnd: Duration(milliseconds: r.end.round()),
                      ));
                    },
                  ),
                ),
                SizedBox(
                  width: 52,
                  child: Text(
                    Formatters.duration(track.usedLength),
                    textAlign: TextAlign.right,
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
                  ),
                ),
              ],
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.only(top: 4, bottom: 6),
                child: Text('Volume shape', style: TextStyle(fontSize: 13, color: context.mutedColor)),
              ),
            ),
            ChipRow<VolumeEnvelope>(
              values: VolumeEnvelope.values,
              selected: track.envelope,
              label: (e) => e.label,
              onSelected: (e) => onChanged(track.copyWith(envelope: e)),
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 34,
              width: double.infinity,
              child: CustomPaint(painter: _EnvelopePainter(track.envelope, scheme.primary)),
            ),
          ],
        ),
      ),
    );
  }
}

/// Small curve showing the selected volume shape.
class _EnvelopePainter extends CustomPainter {
  _EnvelopePainter(this.envelope, this.color);
  final VolumeEnvelope envelope;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path();
    final fill = Path()..moveTo(0, size.height);
    const steps = 60;
    for (var i = 0; i <= steps; i++) {
      final x = i / steps;
      final y = size.height - envelope.levelAt(x).clamp(0, 1.2) / 1.2 * size.height;
      if (i == 0) {
        path.moveTo(0, y);
      } else {
        path.lineTo(x * size.width, y);
      }
      fill.lineTo(x * size.width, y);
    }
    fill
      ..lineTo(size.width, size.height)
      ..close();
    canvas.drawPath(fill, Paint()..color = color.withValues(alpha: 0.12));
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(_EnvelopePainter old) => old.envelope != envelope || old.color != color;
}
