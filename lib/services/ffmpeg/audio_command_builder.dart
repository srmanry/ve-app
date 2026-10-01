import 'dart:math' as math;

import '../../domain/entities/audio_edit.dart';
import '../video/video_processing_service.dart';

/// Translates an [AudioJob] into FFmpeg arguments.
///
/// Pure Dart, unit-tested directly. Every job is one `-filter_complex`
/// graph ending in `[out]`:
///
/// ```
///  single: [0:a] ─ atrim (keep) / asplit+atrim+concat (remove) ─┐
///  merge:  [i:a] ─ aformat ─ concat / acrossfade chain ─────────┼─► finish ─► [out]
///  mix:    [i:a] ─ atrim ─ volume/envelope ─ adelay ─ amix ─ alimiter ─┘
///  finish: cleanup ─ volume ─ loudnorm ─ atempo ─ afade in/out
/// ```
class AudioCommandBuilder {
  const AudioCommandBuilder();

  static const sampleRate = 44100;
  static const _format = 'aformat=sample_fmts=fltp:sample_rates=$sampleRate:channel_layouts=stereo';

  List<String> build(AudioJob job, String output) {
    final inputs = job.inputs;
    return [
      '-hide_banner',
      '-y',
      for (var i = 0; i < inputs.length; i++) ...[
        // -stream_loop is an input option, so it goes before its own -i.
        if (job.loops(i)) ...['-stream_loop', '-1'],
        '-i',
        inputs[i].path,
      ],
      '-filter_complex',
      graph(job),
      '-map',
      '[out]',
      ..._encoder(job),
      output,
    ];
  }

  /// Raw mono 16-bit PCM for waveform drawing.
  List<String> buildPcm({
    required String input,
    required String output,
    required int sampleRate,
    Duration? duration,
  }) => [
    '-hide_banner',
    '-y',
    if (duration != null) ...['-t', _sec(duration)],
    '-i',
    input,
    '-vn',
    '-map',
    '0:a:0',
    '-ac',
    '1',
    '-ar',
    '$sampleRate',
    '-f',
    's16le',
    '-c:a',
    'pcm_s16le',
    output,
  ];

  String graph(AudioJob job) {
    final g = StringBuffer();
    final String body = switch (job.kind) {
      AudioJobKind.single => _single(job, g),
      AudioJobKind.merge => _merge(job, g),
      AudioJobKind.mix => _mix(job, g),
    };
    final finish = _finish(job);
    g.write('$body${finish.isEmpty ? 'anull' : finish.join(',')}[out]');
    return g.toString();
  }

  // ---------------------------------------------------------------- single

  /// Writes any pre-graph to [g] and returns the start of the last chain
  /// (a label or filter prefix the finish filters attach to).
  String _single(AudioJob job, StringBuffer g) {
    final total = job.inputs.first.duration;
    final (s, e) = job.selection;
    final trimsHead = s > Duration.zero;
    final trimsTail = e < total;

    if (!job.removeSelection) {
      if (!trimsHead && !trimsTail) return '[0:a]$_format,';
      return '[0:a]$_format,${_atrim(trimsHead ? s : null, trimsTail ? e : null)},';
    }

    // Remove the selection: keep [0, s) and [e, end).
    if (!trimsHead && !trimsTail) {
      // Removing everything would leave nothing; treat as no cut.
      return '[0:a]$_format,';
    }
    if (!trimsHead) return '[0:a]$_format,${_atrim(e, null)},';
    if (!trimsTail) return '[0:a]$_format,${_atrim(null, s)},';
    g.write(
      '[0:a]$_format,asplit=2[sa][sb];'
      '[sa]${_atrim(null, s)}[p0];'
      '[sb]${_atrim(e, null)}[p1];'
      '[p0][p1]concat=n=2:v=0:a=1[cut];',
    );
    return '[cut]';
  }

  // ----------------------------------------------------------------- merge

  String _merge(AudioJob job, StringBuffer g) {
    final n = job.sources.length;
    for (var i = 0; i < n; i++) {
      // Same format on every input, so sources with different sample rates
      // or channel counts join cleanly.
      g.write('[$i:a]$_format[m$i];');
    }
    final xf = job.effectiveCrossfade;
    if (n == 1) return '[m0]';
    if (xf <= Duration.zero) {
      g.write('${[for (var i = 0; i < n; i++) '[m$i]'].join()}concat=n=$n:v=0:a=1[joined];');
    } else {
      var prev = '[m0]';
      for (var i = 1; i < n; i++) {
        final label = i == n - 1 ? '[joined]' : '[x$i]';
        g.write('$prev[m$i]acrossfade=d=${_sec(xf)}:c1=tri:c2=tri$label;');
        prev = label;
      }
    }
    return '[joined]';
  }

  // ------------------------------------------------------------------- mix

  String _mix(AudioJob job, StringBuffer g) {
    final n = job.tracks.length;
    for (var i = 0; i < n; i++) {
      final t = job.tracks[i];
      final looped = job.loops(i);
      final chain = <String>[
        _format,
        // A looped layer repeats the whole file, so trims don't apply.
        if (!looped && t.isTrimmed)
          _atrim(t.trimStart > Duration.zero ? t.trimStart : null,
              t.usedEnd < t.sourceDuration ? t.usedEnd : null),
        // Level before the delay: an envelope is measured on the track's
        // own time, not the mix timeline.
        _volume(t, looped),
        // all=1 delays every channel without knowing the channel count.
        if (t.start > Duration.zero) 'adelay=${t.start.inMilliseconds}:all=1',
      ];
      g.write('[$i:a]${chain.join(',')}[t$i];');
    }
    // normalize=0 keeps chosen volumes literal (a quiet layer stays quiet);
    // the limiter catches peaks from summing. level=0 disables its auto-gain.
    g.write(
      '${[for (var i = 0; i < n; i++) '[t$i]'].join()}'
      'amix=inputs=$n:duration=${job.mixLength.ffmpegValue}'
      ':dropout_transition=0:normalize=0,'
      'alimiter=limit=0.95:level=0[mixed];',
    );
    return '[mixed]';
  }

  String _volume(MixTrack t, bool looped) {
    final length = t.usedLength;
    if (looped || t.envelope == VolumeEnvelope.flat || length <= Duration.zero) {
      return 'volume=${_num(t.volume)}';
    }
    // eval=frame re-evaluates the expression as the audio runs.
    return "volume=volume='${envelopeExpression(t.envelope, length, t.volume)}':eval=frame";
  }

  /// The envelope as an expression of `t` (seconds). Each run between two
  /// points is a term active only in its own span, easing along the same
  /// S-curve as [VolumeEnvelope.levelAt].
  static String envelopeExpression(VolumeEnvelope envelope, Duration length, double volume) {
    final seconds = length.inMilliseconds / 1000;
    final pts = [for (final p in envelope.points) (seconds * p.position, p.level * volume)];
    final terms = <String>[];
    for (var i = 0; i < pts.length - 1; i++) {
      final (t0, l0) = pts[i];
      final (t1, l1) = pts[i + 1];
      final span = t1 - t0;
      if (span <= 0) continue;
      final String ramp;
      if ((l1 - l0).abs() < 0.0005) {
        ramp = _num(l0);
      } else {
        // Held at 1 past the run's end so the last run can't curve back.
        final x = 'min((t-${_num(t0)})/${_num(span)},1)';
        ramp = '(${_num(l0)}+${_num(l1 - l0)}*$x*$x*(3-2*$x))';
      }
      // The last run also covers anything past the measured end.
      final window = i == pts.length - 2
          ? 'gte(t,${_num(t0)})'
          : 'gte(t,${_num(t0)})*lt(t,${_num(t1)})';
      terms.add('$window*$ramp');
    }
    return terms.isEmpty ? _num(volume) : terms.join('+');
  }

  // ---------------------------------------------------------------- finish

  List<String> _finish(AudioJob job) {
    final out = job.outputDuration;
    final fadeIn = _clampFade(job.fadeIn, out);
    final fadeOut = _clampFade(job.fadeOut, out);
    return [
      if (job.cleanup case final CleanupSettings c) ...cleanupFilters(c),
      if ((job.volume - 1).abs() > 1e-3) 'volume=${_num(job.volume)}',
      if (job.normalize) 'loudnorm=I=-16:TP=-1.5:LRA=11',
      ..._atempo(job.speed),
      if (fadeIn > Duration.zero) 'afade=t=in:st=0:d=${_sec(fadeIn)}:curve=tri',
      if (fadeOut > Duration.zero)
        'afade=t=out:st=${_sec(out - fadeOut)}:d=${_sec(fadeOut)}:curve=tri',
    ];
  }

  /// Signal-processing cleanup (see [CleanupMode]).
  static List<String> cleanupFilters(CleanupSettings c) {
    final denoise = 'afftdn=nr=${c.strength.reductionDb}:nf=${c.strength.floorDb}:tn=1';
    return switch (c.mode) {
      // Below 80 Hz is rumble and handling noise, cut before measuring.
      CleanupMode.backgroundNoise => ['highpass=f=80', denoise],
      // Speech lives roughly between 200 Hz and 3.4 kHz.
      CleanupMode.voiceFocus => ['highpass=f=200', 'lowpass=f=3400', denoise],
      // Lead vocals sit in the centre, so subtracting the channels cancels
      // them; anything panned to a side survives.
      CleanupMode.removeVocals => ['pan=stereo|c0=c0-c1|c1=c1-c0'],
    };
  }

  static Duration _clampFade(Duration fade, Duration total) {
    if (fade <= Duration.zero || total <= Duration.zero) return Duration.zero;
    final cap = total ~/ 2;
    return fade > cap ? cap : fade;
  }

  static List<String> _atempo(double speed) {
    if ((speed - 1).abs() < 1e-6) return const [];
    // atempo accepts 0.5 … 2 per instance; chain for anything outside.
    final out = <String>[];
    var s = speed;
    while (s > 2) {
      out.add('atempo=2');
      s /= 2;
    }
    while (s < 0.5) {
      out.add('atempo=0.5');
      s /= 0.5;
    }
    out.add('atempo=${_num(s)}');
    return out;
  }

  /// `atrim` keeps original timestamps; `asetpts` rebases them to zero so
  /// later delays/fades are measured from the right place.
  static String _atrim(Duration? start, Duration? end) => [
    'atrim=${[if (start != null) 'start=${_sec(start)}', if (end != null) 'end=${_sec(end)}'].join(':')}',
    'asetpts=PTS-STARTPTS',
  ].join(',');

  List<String> _encoder(AudioJob job) => [
    ...switch (job.format) {
      AudioOutputFormat.mp3 => ['-c:a', 'libmp3lame', '-b:a', '${job.quality.kbps}k'],
      AudioOutputFormat.m4a => ['-c:a', 'aac', '-b:a', '${job.quality.kbps}k'],
      AudioOutputFormat.wav => ['-c:a', 'pcm_s16le'],
    },
    '-ar',
    '$sampleRate',
    if (job.mono) ...['-ac', '1'],
  ];

  static String _sec(Duration d) => (math.max(0, d.inMicroseconds) / 1e6).toStringAsFixed(3);

  static String _num(double v) {
    final s = v.toStringAsFixed(4);
    return s.contains('.') ? s.replaceFirst(RegExp(r'\.?0+$'), '') : s;
  }
}
