import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';

import '../../app/providers.dart';
import '../../core/errors/app_exception.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/formatters.dart';
import '../../domain/entities/audio_edit.dart';
import '../../domain/entities/exported_media.dart';
import '../../services/export/export_service.dart';
import '../../services/video/video_processing_service.dart';
import '../editor/panels/panel_common.dart';
import '../exports/export_actions.dart';
import '../widgets/app_dialogs.dart';

// ------------------------------------------------------------------ layout

/// Bold small heading above a group of options.
class OptionLabel extends StatelessWidget {
  const OptionLabel(this.text, {super.key, this.trailing});
  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 18, bottom: 8),
    child: Row(
      children: [
        Expanded(
          child: Text(text, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
        ),
        ?trailing,
      ],
    ),
  );
}

/// Muted one-line explanation under an option.
class OptionHint extends StatelessWidget {
  const OptionHint(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 6),
    child: Text(text, style: TextStyle(fontSize: 12, color: context.mutedColor)),
  );
}

/// A picked file: icon, name, duration, optional actions.
class AudioFileCard extends StatelessWidget {
  const AudioFileCard({
    super.key,
    required this.name,
    required this.duration,
    this.icon = Icons.music_note_rounded,
    this.trailing,
    this.subtitle,
  });

  final String name;
  final Duration duration;
  final IconData icon;
  final Widget? trailing;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
        child: Row(
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: scheme.primary.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, color: scheme.primary),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle ?? Formatters.duration(duration),
                    style: TextStyle(fontSize: 12, color: context.mutedColor),
                  ),
                ],
              ),
            ),
            ?trailing,
          ],
        ),
      ),
    );
  }
}

/// Format + bitrate pickers.
class OutputOptions extends StatelessWidget {
  const OutputOptions({
    super.key,
    required this.format,
    required this.quality,
    required this.onFormat,
    required this.onQuality,
  });

  final AudioOutputFormat format;
  final AudioQuality quality;
  final ValueChanged<AudioOutputFormat> onFormat;
  final ValueChanged<AudioQuality> onQuality;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const OptionLabel('Format'),
      ChipRow<AudioOutputFormat>(
        values: AudioOutputFormat.values,
        selected: format,
        label: (f) => f.label,
        onSelected: onFormat,
      ),
      OptionHint(format.hint),
      if (format.hasBitrate) ...[
        const OptionLabel('Quality'),
        ChipRow<AudioQuality>(
          values: AudioQuality.selectable,
          selected: quality,
          label: (q) => q.label,
          onSelected: onQuality,
        ),
        OptionHint('${quality.hint} · about ${Formatters.fileSize(quality.kbps * 125 * 60)} per minute'),
      ],
    ],
  );
}

/// Slider row with a value label, for seconds / percentages.
class ValueSlider extends StatelessWidget {
  const ValueSlider({
    super.key,
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    required this.format,
    this.divisions,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final ValueChanged<double> onChanged;
  final String Function(double) format;
  final int? divisions;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      SizedBox(width: 86, child: Text(label, style: const TextStyle(fontSize: 13))),
      Expanded(
        child: Slider(
          value: value.clamp(min, max),
          min: min,
          max: max,
          divisions: divisions,
          label: format(value),
          onChanged: onChanged,
        ),
      ),
      SizedBox(
        width: 52,
        child: Text(
          format(value),
          textAlign: TextAlign.right,
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
        ),
      ),
    ],
  );
}

String formatSeconds(double s) => s == 0 ? 'Off' : '${s.toStringAsFixed(s < 10 ? 1 : 0)} s';

String formatPercent(double v) => '${(v * 100).round()}%';

// ----------------------------------------------------------------- preview

/// One shared player for previewing audio files (or a range of one).
class AudioPreviewPlayer extends ChangeNotifier {
  VideoPlayerController? _controller;
  String? _path;
  Duration? _until;
  Timer? _ticker;
  bool _disposed = false;

  String? get path => _path;
  bool get isPlaying => _controller?.value.isPlaying ?? false;
  Duration get position => _controller?.value.position ?? Duration.zero;

  /// Plays [path] from [from], stopping at [until] (null = end).
  Future<void> play(String path, {Duration from = Duration.zero, Duration? until}) async {
    try {
      if (_path != path || _controller == null) {
        await _release();
        final c = VideoPlayerController.file(File(path));
        _controller = c;
        _path = path;
        await c.initialize();
        c.addListener(_onTick);
      }
      if (_disposed) return;
      _until = until;
      await _controller!.seekTo(from);
      await _controller!.play();
      _ticker?.cancel();
      // The controller only reports position changes sparsely; poll so the
      // playhead moves smoothly and the range end is honoured.
      _ticker = Timer.periodic(const Duration(milliseconds: 50), (_) => _onTick());
      notifyListeners();
    } catch (e) {
      await _release();
      notifyListeners();
      throw AppException(AppErrorKind.unsupportedCodec, 'This audio can\'t be previewed.',
          debugDetails: '$e');
    }
  }

  Future<void> pause() async {
    _ticker?.cancel();
    await _controller?.pause();
    if (!_disposed) notifyListeners();
  }

  void _onTick() {
    final c = _controller;
    if (c == null || _disposed) return;
    final v = c.value;
    final until = _until;
    if (v.isPlaying && until != null && v.position >= until) {
      unawaited(pause());
      return;
    }
    if (!v.isPlaying) _ticker?.cancel();
    notifyListeners();
  }

  Future<void> _release() async {
    _ticker?.cancel();
    final c = _controller;
    _controller = null;
    _path = null;
    if (c != null) {
      c.removeListener(_onTick);
      await c.dispose();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_release());
    super.dispose();
  }
}

/// Round play/pause button for a file in an [AudioPreviewPlayer].
class PreviewButton extends StatelessWidget {
  const PreviewButton({
    super.key,
    required this.player,
    required this.path,
    this.from = Duration.zero,
    this.until,
  });

  final AudioPreviewPlayer player;
  final String path;
  final Duration from;
  final Duration? until;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: player,
    builder: (context, _) {
      final playing = player.isPlaying && player.path == path;
      return IconButton(
        tooltip: playing ? 'Pause' : 'Play',
        onPressed: () async {
          try {
            if (playing) {
              await player.pause();
            } else {
              await player.play(path, from: from, until: until);
            }
          } catch (e) {
            if (context.mounted) await showAppError(context, e);
          }
        },
        icon: Icon(playing ? Icons.pause_circle_filled_rounded : Icons.play_circle_fill_rounded),
        iconSize: 34,
        color: Theme.of(context).colorScheme.primary,
      );
    },
  );
}

// ---------------------------------------------------------------- waveform

/// Loads and draws the waveform of a file, with an optional selection.
class WaveformView extends ConsumerWidget {
  const WaveformView({
    super.key,
    required this.path,
    required this.duration,
    this.selectionStart,
    this.selectionEnd,
    this.removeSelection = false,
    this.position,
    this.onSelectionChanged,
    this.height = 96,
  });

  final String path;
  final Duration duration;
  final Duration? selectionStart;
  final Duration? selectionEnd;
  final bool removeSelection;
  final Duration? position;
  final void Function(Duration start, Duration end)? onSelectionChanged;
  final double height;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final future = ref.watch(waveformServiceProvider).peaks(path, duration);
    return FutureBuilder<List<double>>(
      future: future,
      builder: (context, snap) {
        final peaks = snap.data;
        return SizedBox(
          height: height,
          child: LayoutBuilder(
            builder: (context, box) {
              final width = box.maxWidth;
              final total = duration.inMicroseconds <= 0 ? 1 : duration.inMicroseconds;
              double xOf(Duration d) => width * d.inMicroseconds / total;
              Duration timeAt(double x) =>
                  Duration(microseconds: ((x / width).clamp(0.0, 1.0) * total).round());

              final start = selectionStart;
              final end = selectionEnd;
              final editable = onSelectionChanged != null && start != null && end != null;
              final painter = _WavePainter(
                peaks: peaks,
                color: Theme.of(context).colorScheme.primary,
                muted: context.mutedColor.withValues(alpha: 0.35),
                start: start == null ? null : xOf(start) / width,
                end: end == null ? null : xOf(end) / width,
                removeSelection: removeSelection,
                position: position == null ? null : xOf(position!) / width,
              );
              final paint = CustomPaint(painter: painter, size: Size(width, height));
              if (!editable) {
                return snap.hasError
                    ? Center(child: Text('Waveform unavailable', style: TextStyle(color: context.mutedColor)))
                    : paint;
              }

              // Drag whichever handle is closer to the touch.
              var dragStart = true;
              const minGap = Duration(milliseconds: 200);
              void update(double x) {
                final t = timeAt(x);
                if (dragStart) {
                  final s = t > end - minGap ? end - minGap : t;
                  onSelectionChanged!(s.isNegative ? Duration.zero : s, end);
                } else {
                  final e = t < start + minGap ? start + minGap : t;
                  onSelectionChanged!(start, e > duration ? duration : e);
                }
              }

              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onHorizontalDragStart: (d) {
                  final x = d.localPosition.dx;
                  dragStart = (x - xOf(start)).abs() <= (x - xOf(end)).abs();
                  update(x);
                },
                onHorizontalDragUpdate: (d) => update(d.localPosition.dx),
                onTapDown: (d) {
                  final x = d.localPosition.dx;
                  dragStart = (x - xOf(start)).abs() <= (x - xOf(end)).abs();
                  update(x);
                },
                child: Stack(
                  children: [
                    paint,
                    if (peaks == null && !snap.hasError)
                      const Center(child: SizedBox.square(dimension: 22, child: CircularProgressIndicator(strokeWidth: 2))),
                  ],
                ),
              );
            },
          ),
        );
      },
    );
  }
}

class _WavePainter extends CustomPainter {
  _WavePainter({
    required this.peaks,
    required this.color,
    required this.muted,
    required this.start,
    required this.end,
    required this.removeSelection,
    required this.position,
  });

  final List<double>? peaks;
  final Color color;
  final Color muted;
  final double? start;
  final double? end;
  final bool removeSelection;
  final double? position;

  @override
  void paint(Canvas canvas, Size size) {
    final bg = Paint()..color = color.withValues(alpha: 0.06);
    canvas.drawRRect(
      RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(12)),
      bg,
    );
    final s = start, e = end;
    bool kept(double f) {
      if (s == null || e == null) return true;
      final inside = f >= s && f <= e;
      return removeSelection ? !inside : inside;
    }

    final data = peaks;
    if (data != null && data.isNotEmpty) {
      final barW = size.width / data.length;
      final on = Paint()..color = color;
      final off = Paint()..color = muted;
      final mid = size.height / 2;
      for (var i = 0; i < data.length; i++) {
        final h = (data[i] * (size.height - 16)).clamp(2.0, size.height - 16);
        final x = i * barW;
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(x + barW * 0.2, mid - h / 2, barW * 0.6, h),
            const Radius.circular(1),
          ),
          kept((i + 0.5) / data.length) ? on : off,
        );
      }
    }

    if (s != null && e != null) {
      final handle = Paint()
        ..color = color
        ..strokeWidth = 3;
      final shade = Paint()..color = color.withValues(alpha: removeSelection ? 0.12 : 0.08);
      canvas.drawRect(Rect.fromLTRB(s * size.width, 0, e * size.width, size.height), shade);
      for (final f in [s, e]) {
        final x = f * size.width;
        canvas.drawLine(Offset(x, 0), Offset(x, size.height), handle);
        canvas.drawCircle(Offset(x, size.height / 2), 7, Paint()..color = color);
        canvas.drawCircle(Offset(x, size.height / 2), 3, Paint()..color = Colors.white);
      }
    }
    final p = position;
    if (p != null && p > 0) {
      final x = p * size.width;
      canvas.drawLine(
        Offset(x, 0),
        Offset(x, size.height),
        Paint()
          ..color = Colors.black87
          ..strokeWidth = 1.5,
      );
    }
  }

  @override
  bool shouldRepaint(_WavePainter old) =>
      old.peaks != peaks ||
      old.start != start ||
      old.end != end ||
      old.position != position ||
      old.removeSelection != removeSelection ||
      old.color != color;
}

// --------------------------------------------------------------------- run

/// Bottom bar of an audio tool: action button → progress → result.
class AudioRunBar extends ConsumerStatefulWidget {
  const AudioRunBar({
    super.key,
    required this.label,
    required this.buildJob,
    required this.baseName,
    this.icon = Icons.check_rounded,
    this.onBusyChanged,
  });

  final String label;
  final IconData icon;

  /// Returns null when the job can't run yet (the builder shows why).
  final AudioJob? Function() buildJob;
  final String Function() baseName;
  final ValueChanged<bool>? onBusyChanged;

  @override
  ConsumerState<AudioRunBar> createState() => _AudioRunBarState();
}

class _AudioRunBarState extends ConsumerState<AudioRunBar> {
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

  Future<void> _run() async {
    final spec = widget.buildJob();
    if (spec == null) return;
    final job = ref.read(exportServiceProvider).exportAudioJob(spec, baseName: widget.baseName());
    setState(() {
      _job = job;
      _progress = 0;
      _result = null;
    });
    widget.onBusyChanged?.call(true);
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
    } finally {
      widget.onBusyChanged?.call(false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final result = _result;
    final running = _job != null && result == null;
    final actions = ExportActions(ref);
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          border: Border(top: BorderSide(color: Theme.of(context).dividerColor.withValues(alpha: 0.4))),
        ),
        child: result != null
            ? Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.check_circle_rounded, color: Color(0xFF10B981)),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(result.fileName,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                            Text(
                              '${Formatters.duration(result.duration)} · ${Formatters.fileSize(result.sizeBytes)} · saved in Exports',
                              style: TextStyle(fontSize: 11.5, color: context.mutedColor),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        tooltip: 'Close',
                        onPressed: () => setState(() {
                          _result = null;
                          _job = null;
                        }),
                        icon: const Icon(Icons.close_rounded),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      PanelAction(icon: Icons.play_arrow_rounded, label: 'Play', onTap: () => actions.play(context, result)),
                      Builder(
                        builder: (context) => PanelAction(
                          icon: Icons.ios_share_rounded,
                          label: 'Share',
                          onTap: () => actions.share(context, result),
                        ),
                      ),
                      PanelAction(
                        icon: Icons.folder_open_outlined,
                        label: 'Location',
                        onTap: () => actions.openLocation(context, result),
                      ),
                    ],
                  ),
                ],
              )
            : running
            ? Row(
                children: [
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Processing… ${(_progress * 100).floor()}%',
                            style: const TextStyle(fontWeight: FontWeight.w600)),
                        const SizedBox(height: 8),
                        LinearProgressIndicator(value: _progress, borderRadius: BorderRadius.circular(4)),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  TextButton(onPressed: () => _job?.cancel(), child: const Text('Cancel')),
                ],
              )
            : SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(50),
                    textStyle: const TextStyle(fontFamily: 'Poppins', fontWeight: FontWeight.w600, fontSize: 15),
                  ),
                  onPressed: _run,
                  icon: Icon(widget.icon),
                  label: Text(widget.label),
                ),
              ),
      ),
    );
  }
}
