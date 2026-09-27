import 'dart:math' as math;

import '../../domain/entities/canvas_settings.dart';
import '../../domain/entities/project_timeline.dart';
import '../../domain/entities/timeline_item.dart';
import '../../domain/entities/video_clip.dart';
import '../../domain/entities/video_effect.dart';
import '../video/color_matrix.dart';
import '../video/video_processing_service.dart';

/// Translates editing intent into FFmpeg argument lists.
///
/// Pure Dart with no plugin dependency, so it is unit-tested directly.
/// Arguments are returned as a list (never a shell string), so file paths
/// with spaces or quotes need no escaping.
///
/// ## Render graph
///
/// ```
///  clip inputs ─► per-clip chain ─► [v0][a0] … [vN][aN]
///     (-ss/-t seek, speed, crop, rotate/flip, fit to canvas, colour, fps)
///                    │
///                    ▼
///  concat (hard cuts) or xfade/acrossfade chain (transitions) ─► [vbase][amain]
///                    │
///  PIP inputs ──────►├─ overlay (timed, positioned, rotated)
///  text/sticker PNGs ►├─ overlay (timed, full-canvas RGBA)
///                    ▼
///  [amain] + music/PIP audio ─► amix ─► [aout]      [vout]
///                    ▼
///            libx264 + AAC  ─► MP4 (+faststart)
/// ```
class FfmpegCommandBuilder {
  const FfmpegCommandBuilder();

  static const _sampleRate = 48000;
  static const _audioFormat =
      'aformat=sample_fmts=fltp:sample_rates=$_sampleRate:channel_layouts=stereo';

  // ---------------------------------------------------------------------------
  // Full project render
  // ---------------------------------------------------------------------------

  List<String> buildRender(RenderRequest request) {
    final project = request.project;
    if (project.clips.isEmpty) {
      throw ArgumentError('Cannot render a project without clips');
    }
    final timeline = ProjectTimeline(project);
    final settings = request.settings;
    final size = timeline.outputSize(settings);
    final w = size.width, h = size.height;
    final fps = settings.frameRate;
    final total = timeline.duration;

    final args = <String>['-hide_banner', '-y'];
    final graph = <String>[];
    var inputIndex = 0;

    // 1. Main track clips.
    for (var i = 0; i < project.clips.length; i++) {
      final clip = project.clips[i];
      final path = request.resolveMedia(clip.sourcePath);
      args.addAll(
        clip.isStill
            ? _stillInput(path, clip.sourceDuration, fps)
            : _seekInput(path, clip.trimStart, clip.sourceDuration),
      );
      final idx = inputIndex++;
      graph.add('[$idx:v]${_clipVideoChain(clip, w, h, fps, project.canvas, i)}[v$i]');
      graph.add(_clipAudioChain(clip, idx, i));
    }

    // 2. Join clips.
    var videoLabel = 'v0', audioLabel = 'a0';
    final hasTransitions = List.generate(
      project.clips.length - 1,
      (i) => timeline.transitionAfter(i) > Duration.zero,
    ).any((t) => t);

    if (project.clips.length > 1 && !hasTransitions) {
      final pads = List.generate(project.clips.length, (i) => '[v$i][a$i]').join();
      graph.add('${pads}concat=n=${project.clips.length}:v=1:a=1[vcat][acat]');
      videoLabel = 'vcat';
      audioLabel = 'acat';
    } else if (project.clips.length > 1) {
      var cursor = project.clips.first.duration;
      for (var i = 1; i < project.clips.length; i++) {
        final t = timeline.transitionAfter(i - 1);
        final nextDuration = project.clips[i].duration;
        final vOut = 'vj$i', aOut = 'aj$i';
        if (t > Duration.zero) {
          final type = project.clips[i - 1].transition.type;
          graph.add(
            '[$videoLabel][v$i]xfade=transition=${type.xfadeName}'
            ':duration=${_sec(t)}:offset=${_sec(cursor - t)}[$vOut]',
          );
          graph.add('[$audioLabel][a$i]acrossfade=d=${_sec(t)}:c1=tri:c2=tri[$aOut]');
          cursor += nextDuration - t;
        } else {
          graph.add('[$videoLabel][v$i]concat=n=2:v=1:a=0[$vOut]');
          graph.add('[$audioLabel][a$i]concat=n=2:v=0:a=1[$aOut]');
          cursor += nextDuration;
        }
        videoLabel = vOut;
        audioLabel = aOut;
      }
    }

    // 3. Extra audio tracks (music, extracted audio).
    final mixLabels = <String>[audioLabel];
    for (var j = 0; j < project.audioTracks.length; j++) {
      final track = project.audioTracks[j];
      if (track.muted || track.volume <= 0 || track.start >= total) continue;
      args.addAll(
        _seekInput(request.resolveMedia(track.sourcePath), track.trimStart, track.duration),
      );
      final idx = inputIndex++;
      final label = 'mt$j';
      graph.add(
        '[$idx:a]asetpts=PTS-STARTPTS,volume=${_num(track.volume)},'
        '$_audioFormat,adelay=delays=${track.start.inMilliseconds}:all=1[$label]',
      );
      mixLabels.add(label);
    }

    // 4. Picture-in-picture layers.
    for (var j = 0; j < project.pipLayers.length; j++) {
      final pip = project.pipLayers[j];
      if (pip.start >= total) continue;
      args.addAll(_seekInput(request.resolveMedia(pip.sourcePath), pip.trimStart, pip.duration));
      final idx = inputIndex++;
      final pipWidth = _even(w * pip.transform.scale.clamp(0.05, 2.0));
      final chain = <String>[
        'setpts=PTS-STARTPTS+${_sec(pip.start)}/TB',
        'scale=$pipWidth:-2',
        'format=rgba',
        if (pip.transform.rotation.abs() > 1e-3) _rotate(pip.transform.rotation),
      ];
      graph.add('[$idx:v]${chain.join(',')}[pip$j]');
      final out = 'vp$j';
      final cx = _num(pip.transform.x * w), cy = _num(pip.transform.y * h);
      graph.add(
        '[$videoLabel][pip$j]overlay=x=$cx-overlay_w/2:y=$cy-overlay_h/2'
        ':eof_action=pass:enable=\'${_between(pip.start, pip.end)}\'[$out]',
      );
      videoLabel = out;
      if (pip.hasAudibleAudio) {
        final label = 'pa$j';
        graph.add(
          '[$idx:a]asetpts=PTS-STARTPTS,volume=${_num(pip.volume)},'
          '$_audioFormat,adelay=delays=${pip.start.inMilliseconds}:all=1[$label]',
        );
        mixLabels.add(label);
      }
    }

    // 5. Rasterised text/sticker overlays (canvas-sized RGBA PNGs).
    for (var j = 0; j < request.overlays.length; j++) {
      final overlay = request.overlays[j];
      args.addAll(['-i', overlay.path]);
      final idx = inputIndex++;
      final out = 'vo$j';
      graph.add(
        '[$videoLabel][$idx:v]overlay=0:0'
        ':enable=\'${_between(overlay.start, overlay.end)}\'[$out]',
      );
      videoLabel = out;
    }

    graph.add('[$videoLabel]format=yuv420p[vout]');

    // 6. Final audio mix.
    if (mixLabels.length > 1) {
      graph.add(
        '${mixLabels.map((l) => '[$l]').join()}'
        'amix=inputs=${mixLabels.length}:duration=first'
        ':dropout_transition=0:normalize=0[aout]',
      );
    } else {
      graph.add('[${mixLabels.first}]anull[aout]');
    }

    final videoKbps = settings.videoBitrateKbps(w, h);
    args.addAll([
      '-filter_complex',
      graph.join(';'),
      '-map',
      '[vout]',
      '-map',
      '[aout]',
      ..._videoEncoderArgs(videoKbps, fps),
      '-c:a',
      'aac',
      '-b:a',
      '${settings.audioBitrateKbps}k',
      '-ar',
      '$_sampleRate',
      '-ac',
      '2',
      '-t',
      _sec(total),
      '-movflags',
      '+faststart',
      request.outputPath,
    ]);
    return args;
  }

  /// `-ss`/`-t` placed *before* `-i`: FFmpeg seeks by keyframe then decodes
  /// accurately to the exact start, and never reads past the end - so long
  /// sources are not decoded in full.
  List<String> _seekInput(String path, Duration start, Duration duration) => [
    if (start > Duration.zero) ...['-ss', _sec(start)],
    '-t',
    _sec(duration),
    '-i',
    path,
  ];

  /// A photo becomes a constant video stream: the single decoded frame is
  /// looped at the output frame rate for exactly [duration].
  List<String> _stillInput(String path, Duration duration, int fps) => [
    '-loop',
    '1',
    '-framerate',
    '$fps',
    '-t',
    _sec(duration),
    '-i',
    path,
  ];

  String _clipVideoChain(VideoClip clip, int w, int h, int fps, CanvasSettings canvas, int i) {
    final filters = <String>[
      clip.speed == 1.0 ? 'setpts=PTS-STARTPTS' : 'setpts=(PTS-STARTPTS)/${_num(clip.speed)}',
    ];
    if (!clip.crop.isFull) {
      final c = clip.crop;
      filters.add(
        'crop=w=iw*${_num(c.width)}:h=ih*${_num(c.height)}'
        ':x=iw*${_num(c.left)}:y=ih*${_num(c.top)}',
      );
    }
    switch (clip.quarterTurns % 4) {
      case 1:
        filters.add('transpose=clock');
      case 2:
        filters.addAll(['hflip', 'vflip']);
      case 3:
        filters.add('transpose=cclock');
    }
    if (clip.flipHorizontal) filters.add('hflip');
    if (clip.flipVertical) filters.add('vflip');
    // Denoise on the source frame, before scaling spreads the noise.
    final videoDenoise = videoDenoiseFilter(clip.videoDenoise);
    if (videoDenoise != null) filters.add(videoDenoise);

    if (canvas.fit == CanvasFit.fill) {
      filters.addAll(['scale=$w:$h:force_original_aspect_ratio=increase', 'crop=$w:$h']);
    } else {
      filters.addAll([
        'scale=$w:$h:force_original_aspect_ratio=decrease:force_divisible_by=2',
        'pad=$w:$h:(ow-iw)/2:(oh-ih)/2:color=${_rgbHex(canvas.backgroundColor)}',
      ]);
    }
    filters.add('setsar=1');

    final matrix = ColorMatrix.forClip(clip);
    if (!ColorMatrix.isIdentity(matrix)) {
      filters.addAll(['format=rgba', _colorChannelMixer(matrix)]);
    }
    final effect = _effectFilter(clip, w, h, i);
    if (effect != null) filters.add(effect);
    filters.addAll([
      'fps=$fps',
      'format=yuv420p',
      // Guarantee the exact nominal length (sources can be a few ms short),
      // which keeps concat/xfade offsets and A/V sync correct.
      'tpad=stop_mode=clone:stop_duration=1',
      'trim=duration=${_sec(clip.duration)}',
      'setpts=PTS-STARTPTS',
      // concat outputs AV_TIME_BASE; xfade requires both inputs to share a
      // timebase, so every clip is normalised to it (mixed cuts+transitions).
      'settb=AVTB',
    ]);
    return filters.join(',');
  }

  String _clipAudioChain(VideoClip clip, int inputIdx, int i) {
    final d = _sec(clip.duration);
    if (!clip.hasAudibleAudio) {
      return 'anullsrc=channel_layout=stereo:sample_rate=$_sampleRate,'
          'atrim=duration=$d,$_audioFormat[a$i]';
    }
    return '[$inputIdx:a]asetpts=PTS-STARTPTS,'
        '${[...audioDenoiseFilters(clip.audioDenoise), ..._atempo(clip.speed), 'volume=${_num(clip.volume)}'].join(',')},'
        '$_audioFormat,apad,atrim=duration=$d,asetpts=PTS-STARTPTS[a$i]';
  }

  /// Effect filters, applied on the full canvas-sized frame so strengths are
  /// relative to the output size (matching the preview). Mirror needs a
  /// small sub-graph, hence the per-clip labels.
  String? _effectFilter(VideoClip clip, int w, int h, int i) {
    final k = clip.effectIntensity.clamp(0.0, 1.0);
    if (k <= 0) return null;
    final minSide = math.min(w, h);
    switch (clip.effect) {
      case VideoEffect.none:
      case VideoEffect.invert: // part of the colour matrix
        return null;
      case VideoEffect.blur:
        return 'gblur=sigma=${_num(math.max(0.5, k * 0.03 * minSide))}';
      case VideoEffect.vignette:
        return 'vignette=angle=${_num(0.35 + k * 0.9)}';
      case VideoEffect.mirror:
        return 'split[mr${i}a][mr${i}b];[mr${i}b]crop=iw/2:ih:0:0,hflip[mr${i}c];'
            '[mr${i}a][mr${i}c]overlay=W/2:0';
      case VideoEffect.glitch:
        final shift = math.max(1, (k * 0.012 * w).round());
        return 'rgbashift=rh=-$shift:bh=$shift';
      case VideoEffect.grain:
        return 'noise=alls=${(k * 40).round()}:allf=t+u';
      case VideoEffect.pixelate:
        final block = 4 + (k * 28).round();
        final pw = math.max(2, (w / block).round());
        final ph = math.max(2, (h / block).round());
        return 'scale=$pw:$ph:flags=neighbor,scale=$w:$h:flags=neighbor';
      case VideoEffect.sharpen:
        return 'unsharp=5:5:${_num(k * 1.5)}';
    }
  }

  /// Picture noise removal (3D denoiser: spatial + temporal).
  static String? videoDenoiseFilter(DenoiseLevel level) => switch (level) {
    DenoiseLevel.off => null,
    DenoiseLevel.light => 'hqdn3d=2:1.5:3:2.25',
    DenoiseLevel.medium => 'hqdn3d=4:3:6:4.5',
    DenoiseLevel.strong => 'hqdn3d=8:6:12:9',
  };

  /// Background-noise removal: FFT denoiser (hiss, hum, wind) plus a
  /// rumble high-pass for the stronger levels.
  static List<String> audioDenoiseFilters(DenoiseLevel level) => switch (level) {
    DenoiseLevel.off => const [],
    DenoiseLevel.light => const ['afftdn=nr=10:nf=-30'],
    DenoiseLevel.medium => const ['highpass=f=70', 'afftdn=nr=18:nf=-28'],
    DenoiseLevel.strong => const ['highpass=f=90', 'afftdn=nr=28:nf=-25:tn=1'],
  };

  /// `atempo` is limited per instance, so extreme speeds are chained
  /// (0.25x = 0.5 * 0.5, 4x = 2 * 2) which also keeps quality reasonable.
  List<String> _atempo(double speed) {
    if ((speed - 1.0).abs() < 1e-6) return const [];
    final out = <String>[];
    var s = speed;
    while (s < 0.5) {
      out.add('atempo=${_num(0.5)}');
      s /= 0.5;
    }
    while (s > 2.0) {
      out.add('atempo=${_num(2.0)}');
      s /= 2.0;
    }
    if ((s - 1.0).abs() > 1e-6) out.add('atempo=${_num(s)}');
    return out;
  }

  String _colorChannelMixer(List<double> m) {
    // Offsets (col 4, 0…255) ride on the opaque alpha channel (255).
    String row(String c, int r) =>
        '${c}r=${_num(m[r * 5])}:${c}g=${_num(m[r * 5 + 1])}'
        ':${c}b=${_num(m[r * 5 + 2])}:${c}a=${_num(m[r * 5 + 4] / 255)}';
    return 'colorchannelmixer=${row('r', 0)}:${row('g', 1)}:${row('b', 2)}';
  }

  String _rotate(double radians) {
    final a = _num(radians);
    return 'rotate=$a:c=none:ow=rotw($a):oh=roth($a)';
  }

  List<String> _videoEncoderArgs(int kbps, int fps) => [
    '-c:v',
    'libx264',
    '-preset',
    'veryfast',
    '-profile:v',
    'high',
    '-pix_fmt',
    'yuv420p',
    '-b:v',
    '${kbps}k',
    '-maxrate',
    '${(kbps * 1.5).round()}k',
    '-bufsize',
    '${kbps * 2}k',
    '-r',
    '$fps',
    '-g',
    '${fps * 2}',
  ];

  // ---------------------------------------------------------------------------
  // Utility jobs
  // ---------------------------------------------------------------------------

  List<String> buildExtractFrame({
    required String input,
    required Duration at,
    required String output,
    required int maxWidth,
  }) => [
    '-hide_banner',
    '-y',
    // One decoder thread: a 4K frame decode with the default thread count
    // allocates a frame buffer per thread, which is costly on phones.
    '-threads',
    '1',
    if (at > Duration.zero) ...['-ss', _sec(at)],
    '-i',
    input,
    '-an',
    '-frames:v',
    '1',
    '-vf',
    "scale='min($maxWidth,iw)':-2",
    '-q:v',
    '4',
    output,
  ];

  List<String> buildExtractAudio(AudioExtractRequest r) {
    final filters = [
      ...audioDenoiseFilters(r.denoise),
      ..._atempo(r.speed),
      if ((r.volume - 1.0).abs() > 1e-6) 'volume=${_num(r.volume)}',
    ];
    return [
      '-hide_banner',
      '-y',
      if (r.start > Duration.zero) ...['-ss', _sec(r.start)],
      if (r.duration != null) ...['-t', _sec(r.duration!)],
      '-i',
      r.input,
      '-vn',
      '-map',
      '0:a:0',
      if (filters.isNotEmpty) ...['-af', filters.join(',')],
      ...switch (r.format) {
        AudioOutputFormat.m4a => ['-c:a', 'aac', '-b:a', '192k'],
        AudioOutputFormat.wav => ['-c:a', 'pcm_s16le'],
      },
      '-ar',
      '$_sampleRate',
      r.output,
    ];
  }

  // ---------------------------------------------------------------------------
  // Stabilization (vid.stab, two passes)
  // ---------------------------------------------------------------------------

  /// Pass 1: analyse camera motion. Output goes to the transforms file only.
  List<String> buildStabilizeDetect(StabilizeJob job, String transformsPath) => [
    '-hide_banner',
    '-y',
    ..._seekInput(job.input, job.start, job.duration),
    '-an',
    '-vf',
    'vidstabdetect=shakiness=${job.level.shakiness}:accuracy=15:result=${_filterPath(transformsPath)}',
    '-f',
    'null',
    '-',
  ];

  /// Pass 2: smooth the camera path, zoom just enough to hide the moving
  /// borders, restore a little sharpness, keep the audio.
  List<String> buildStabilizeTransform(StabilizeJob job, String transformsPath, String output) => [
    '-hide_banner',
    '-y',
    ..._seekInput(job.input, job.start, job.duration),
    '-vf',
    [
      'vidstabtransform=input=${_filterPath(transformsPath)}'
          ':smoothing=${job.level.smoothing}:optzoom=1:interpol=bicubic',
      'unsharp=5:5:0.6:3:3:0.3',
      'format=yuv420p',
    ].join(','),
    '-map',
    '0:v:0',
    '-map',
    '0:a:0?',
    '-c:v',
    'libx264',
    '-preset',
    'veryfast',
    '-crf',
    '18',
    '-c:a',
    'aac',
    '-b:a',
    '192k',
    '-movflags',
    '+faststart',
    output,
  ];

  /// Escapes a path for use as a filter option value (':' and '\\' are
  /// special in filtergraph syntax; the whole value is quoted).
  static String _filterPath(String path) =>
      "'${path.replaceAll(r'\\', r'\\\\').replaceAll("'", r"'\\''")}'";

  // ---------------------------------------------------------------------------
  // AI background removal
  // ---------------------------------------------------------------------------

  /// Small JPEG frames for the segmentation model ([BackgroundJob.fps] per
  /// second for videos, a single frame for photos).
  List<String> buildSegmentationFrames(BackgroundJob job, String outputPattern) => [
    '-hide_banner',
    '-y',
    ...job.isStill ? ['-i', job.input] : _seekInput(job.input, job.start, job.duration),
    if (job.isStill) ...['-frames:v', '1'],
    '-vf',
    [if (!job.isStill) 'fps=${job.fps}', 'scale=${job.maskWidth}:${job.maskHeight}'].join(','),
    '-q:v',
    '3',
    outputPattern,
  ];

  /// Composites the person (source × mask) over the new background.
  ///
  /// The masks arrive as one raw 8-bit grayscale stream (one frame per
  /// segmented image), are upscaled and slightly feathered, then used as
  /// alpha via `alphamerge`. Masks run at a lower frame rate than the video;
  /// the last mask is held until the next one (framesync).
  List<String> buildBackgroundComposite(BackgroundJob job, String masksPath, String output) {
    final w = job.outputWidth, h = job.outputHeight;
    final args = <String>[
      '-hide_banner',
      '-y',
      ...job.isStill ? ['-i', job.input] : _seekInput(job.input, job.start, job.duration),
      '-f',
      'rawvideo',
      '-pix_fmt',
      'gray',
      '-video_size',
      '${job.maskWidth}x${job.maskHeight}',
      '-framerate',
      '${job.isStill ? 1 : job.fps}',
      '-i',
      masksPath,
    ];
    final fill = job.fill;
    if (fill.imagePath != null) {
      args.addAll(
        job.isStill ? ['-i', fill.imagePath!] : _stillInput(fill.imagePath!, job.duration, 30),
      );
    }
    final graph = <String>[
      '[0:v]scale=$w:$h,setsar=1,format=yuv420p${fill.blur ? ',split[fgsrc][bgsrc]' : '[fgsrc]'}',
      '[1:v]scale=$w:$h:flags=bicubic,gblur=sigma=1.2,format=gray[mask]',
      '[fgsrc][mask]alphamerge[fg]',
      if (fill.blur)
        '[bgsrc]gblur=sigma=${_num(math.max(w, h) * 0.02)}[bg]'
      else if (fill.imagePath != null)
        '[2:v]scale=$w:$h:force_original_aspect_ratio=increase,crop=$w:$h,setsar=1[bg]'
      else
        'color=c=${_rgbHex(fill.color)}:s=${w}x$h:r=${job.isStill ? 1 : 30}'
            ':d=${_sec(job.isStill ? const Duration(seconds: 1) : job.duration)}[bg]',
      '[bg][fg]overlay=shortest=1:format=auto[out]',
    ];
    args.addAll(['-filter_complex', graph.join(';'), '-map', '[out]']);
    if (job.isStill) {
      args.addAll(['-frames:v', '1', '-q:v', '2', output]);
    } else {
      args.addAll([
        '-map',
        '0:a?',
        '-c:v',
        'libx264',
        '-preset',
        'veryfast',
        '-crf',
        '18',
        '-pix_fmt',
        'yuv420p',
        '-c:a',
        'aac',
        '-b:a',
        '192k',
        '-movflags',
        '+faststart',
        output,
      ]);
    }
    return args;
  }

  /// Converts a normalised photo (PNG) to a compact JPEG for storage.
  List<String> buildImageToJpeg({required String input, required String output}) => [
    '-hide_banner',
    '-y',
    '-i',
    input,
    '-frames:v',
    '1',
    '-q:v',
    '3',
    output,
  ];

  List<String> buildEditingProxy({required String input, required String output}) => [
    '-hide_banner',
    '-y',
    '-i',
    input,
    '-map',
    '0:v:0',
    '-map',
    '0:a:0?',
    '-c:v',
    'libx264',
    '-preset',
    'veryfast',
    '-crf',
    '18',
    '-pix_fmt',
    'yuv420p',
    '-c:a',
    'aac',
    '-b:a',
    '192k',
    '-movflags',
    '+faststart',
    output,
  ];

  // ---------------------------------------------------------------------------
  // Formatting helpers
  // ---------------------------------------------------------------------------

  static String _sec(Duration d) => (math.max(0, d.inMicroseconds) / 1e6).toStringAsFixed(3);

  static String _num(double v) {
    final s = v.toStringAsFixed(4);
    // Trim trailing zeros for readability: 1.5000 -> 1.5, 2.0000 -> 2
    return s.contains('.') ? s.replaceFirst(RegExp(r'\.?0+$'), '') : s;
  }

  static int _even(double v) => math.max(2, (v / 2).round() * 2);

  static String _between(Duration start, Duration end) => 'between(t,${_sec(start)},${_sec(end)})';

  static String _rgbHex(int argb) => '0x${(argb & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';
}
