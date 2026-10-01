import 'dart:async';

import '../../domain/entities/audio_edit.dart';
import '../../domain/entities/export_settings.dart';
import '../../domain/entities/image_edit.dart';
import '../../domain/entities/media_info.dart';
import '../../domain/entities/project.dart';
import '../../domain/entities/video_effect.dart';

/// Engine-agnostic contract for all local media processing.
///
/// The UI and the export pipeline only talk to this interface. The current
/// implementation is FFmpeg (`FfmpegVideoProcessingService`); a different
/// engine (e.g. platform-native AVFoundation / Media3 Transformer) can be
/// dropped in without touching presentation code.
abstract interface class VideoProcessingService {
  /// Reads technical metadata. Throws `AppException` for unreadable files.
  Future<MediaInfo> probe(String absolutePath);

  /// Writes a single JPEG frame at [at] scaled to [maxWidth].
  Future<void> extractFrame({
    required String input,
    required Duration at,
    required String output,
    int maxWidth = 240,
  });

  /// Renders a full project to a video file.
  ProcessingTask render(RenderRequest request);

  /// Writes the audio of [input] (optionally a section / speed-changed).
  ProcessingTask extractAudio(AudioExtractRequest request);

  /// Converts a file to an H.264/AAC MP4 that every platform player can
  /// preview. Used on import for containers/codecs the device can't play.
  ProcessingTask transcodeForEditing({
    required String input,
    required String output,
    required Duration duration,
  });

  /// Writes small frames for person segmentation (see [BackgroundJob]).
  ProcessingTask extractSegmentationFrames(BackgroundJob job, String outputPattern);

  /// Replaces the background using per-frame masks (raw 8-bit gray).
  ProcessingTask compositeBackground(BackgroundJob job, String masksPath, String output);

  /// Stabilization pass 1: measures camera motion into [transformsPath].
  ProcessingTask stabilizeDetect(StabilizeJob job, String transformsPath);

  /// Stabilization pass 2: applies the smoothed motion and encodes [output].
  ProcessingTask stabilizeTransform(StabilizeJob job, String transformsPath, String output);

  /// Runs one audio tool job (cut, convert, merge, mix, clean…) to [output].
  ProcessingTask processAudio(AudioJob job, String output);

  /// Decodes [input]'s audio to raw mono 16-bit PCM at [sampleRate] (for
  /// drawing waveforms).
  ProcessingTask decodePcm({
    required String input,
    required String output,
    required int sampleRate,
    Duration? duration,
  });

  /// Resizes / re-encodes one photo (image tools).
  Future<void> processImage(ImageJob job, String output);

  /// Re-encodes a photo (e.g. a normalised PNG) as JPEG.
  Future<void> convertImage({required String input, required String output});

  /// Cancels every running job (used on app shutdown / temp cleanup).
  Future<void> cancelAll();
}

/// Progress of a running [ProcessingTask].
class ProcessingProgress {
  const ProcessingProgress({required this.fraction, required this.processed});

  /// 0 … 1, or null when unknown.
  final double? fraction;

  /// Output media time produced so far.
  final Duration processed;
}

/// Handle for a long-running background job. Work runs natively off the
/// UI isolate; this object only relays progress and completion.
abstract interface class ProcessingTask {
  Stream<ProcessingProgress> get progress;

  /// Completes when the job succeeds; throws `AppException` on failure
  /// (kind `cancelled` after [cancel]).
  Future<void> get done;

  Future<void> cancel();
}

/// A still image composited over the video between [start] and [end].
/// Text and sticker layers are rasterised by Flutter to canvas-sized PNGs
/// so export matches the preview pixel-for-pixel.
class OverlayImage {
  const OverlayImage({required this.path, required this.start, required this.end});
  final String path;
  final Duration start;
  final Duration end;
}

class RenderRequest {
  const RenderRequest({
    required this.project,
    required this.settings,
    required this.resolveMedia,
    required this.outputPath,
    this.overlays = const [],
  });

  final Project project;
  final ExportSettings settings;

  /// Maps a stored (relative) media path to an absolute path.
  final String Function(String relativePath) resolveMedia;
  final String outputPath;
  final List<OverlayImage> overlays;
}

enum AudioOutputFormat {
  mp3('MP3', 'mp3', 'Plays everywhere'),
  m4a('M4A (AAC)', 'm4a', 'Small file, great quality'),
  wav('WAV', 'wav', 'Uncompressed, best for editing (large)');

  const AudioOutputFormat(this.label, this.extension, this.hint);
  final String label;
  final String extension;
  final String hint;

  /// WAV is uncompressed PCM, so it takes no bitrate.
  bool get hasBitrate => this != wav;
}

class AudioExtractRequest {
  const AudioExtractRequest({
    required this.input,
    required this.output,
    required this.format,
    this.start = Duration.zero,
    this.duration,
    this.speed = 1.0,
    this.volume = 1.0,
    this.denoise = DenoiseLevel.off,
    this.quality = AudioQuality.kbps192,
  });

  final String input;
  final String output;
  final AudioOutputFormat format;
  final AudioQuality quality;
  final Duration start;

  /// Source duration to read; null = until the end.
  final Duration? duration;
  final double speed;
  final double volume;

  /// Background-noise removal applied while extracting.
  final DenoiseLevel denoise;
}

/// What replaces the removed background.
class BackgroundFill {
  const BackgroundFill.color(this.color) : blur = false, imagePath = null;
  const BackgroundFill.blur() : blur = true, color = 0xFF000000, imagePath = null;
  const BackgroundFill.image(String absolutePath)
    : imagePath = absolutePath,
      blur = false,
      color = 0xFF000000;

  /// ARGB colour when neither [blur] nor [imagePath] is used.
  final int color;

  /// Blurred version of the original footage.
  final bool blur;

  /// Absolute path of a photo to place behind the person.
  final String? imagePath;
}

/// Geometry and timing of one background-removal job.
class BackgroundJob {
  BackgroundJob({
    required this.input,
    required this.isStill,
    required this.start,
    required this.duration,
    required this.displayWidth,
    required this.displayHeight,
    required this.fill,
    this.fps = 15,
  });

  final String input;
  final bool isStill;
  final Duration start;
  final Duration duration;
  final int displayWidth;
  final int displayHeight;
  final BackgroundFill fill;

  /// Mask frames per second (the video keeps its own frame rate).
  final int fps;

  static const maskLongSide = 512;
  static const outputLongSide = 1920;

  static int _even(double v) => ((v / 2).round() * 2).clamp(2, 100000);

  double get _maskScale =>
      maskLongSide / (displayWidth > displayHeight ? displayWidth : displayHeight);
  double get _outScale {
    final s = outputLongSide / (displayWidth > displayHeight ? displayWidth : displayHeight);
    return s > 1 ? 1 : s;
  }

  late final int maskWidth = _even(displayWidth * _maskScale);
  late final int maskHeight = _even(displayHeight * _maskScale);
  late final int outputWidth = _even(displayWidth * _outScale);
  late final int outputHeight = _even(displayHeight * _outScale);
}

/// How hard to smooth camera shake.
enum StabilizeLevel {
  light('Light', shakiness: 4, smoothing: 10),
  medium('Medium', shakiness: 6, smoothing: 18),
  strong('Strong', shakiness: 9, smoothing: 30);

  const StabilizeLevel(this.label, {required this.shakiness, required this.smoothing});
  final String label;

  /// vid.stab detection sensitivity (1–10).
  final int shakiness;

  /// Frames averaged for the camera path (higher = steadier, more crop).
  final int smoothing;
}

/// One stabilization job over the used section of a video.
class StabilizeJob {
  const StabilizeJob({
    required this.input,
    required this.start,
    required this.duration,
    required this.level,
  });

  final String input;
  final Duration start;
  final Duration duration;
  final StabilizeLevel level;
}

/// One input of an [AudioJob].
class AudioSource {
  const AudioSource(this.path, this.duration);

  /// Absolute path (audio, or a video whose first audio track is used).
  final String path;
  final Duration duration;
}

enum AudioJobKind { single, merge, mix }

/// An audio tool job. One graph shape per [kind]:
///
/// * single: optional cut (keep or remove a selection) of one source.
/// * merge: sources played one after another, optionally cross-faded.
/// * mix: [tracks] layered on one timeline (each with its own start,
///   trim, volume and envelope), summed and limited.
///
/// The "finish" settings (cleanup, volume, loudness, speed, fades, encoding)
/// apply to the result of every kind.
class AudioJob {
  const AudioJob.single({
    required AudioSource source,
    this.selectionStart,
    this.selectionEnd,
    this.removeSelection = false,
    this.cleanup,
    this.volume = 1.0,
    this.normalize = false,
    this.speed = 1.0,
    this.fadeIn = Duration.zero,
    this.fadeOut = Duration.zero,
    required this.format,
    this.quality = AudioQuality.kbps192,
    this.mono = false,
  }) : kind = AudioJobKind.single,
       sources = const [],
       _single = source,
       crossfade = Duration.zero,
       tracks = const [],
       mixLength = MixLength.main,
       loopShorter = false;

  const AudioJob.merge({
    required this.sources,
    this.crossfade = Duration.zero,
    this.cleanup,
    this.volume = 1.0,
    this.normalize = false,
    this.speed = 1.0,
    this.fadeIn = Duration.zero,
    this.fadeOut = Duration.zero,
    required this.format,
    this.quality = AudioQuality.kbps192,
    this.mono = false,
  }) : kind = AudioJobKind.merge,
       _single = null,
       selectionStart = null,
       selectionEnd = null,
       removeSelection = false,
       tracks = const [],
       mixLength = MixLength.main,
       loopShorter = false;

  const AudioJob.mix({
    required this.tracks,
    this.mixLength = MixLength.main,
    this.loopShorter = false,
    this.normalize = false,
    this.speed = 1.0,
    this.fadeIn = Duration.zero,
    this.fadeOut = Duration.zero,
    required this.format,
    this.quality = AudioQuality.kbps192,
    this.mono = false,
  }) : kind = AudioJobKind.mix,
       _single = null,
       sources = const [],
       selectionStart = null,
       selectionEnd = null,
       removeSelection = false,
       crossfade = Duration.zero,
       cleanup = null,
       volume = 1.0;

  final AudioJobKind kind;
  final AudioSource? _single;
  final List<AudioSource> sources;

  // single
  final Duration? selectionStart;
  final Duration? selectionEnd;

  /// Cut the selection out instead of keeping only it.
  final bool removeSelection;

  // merge
  final Duration crossfade;

  // mix
  final List<MixTrack> tracks;
  final MixLength mixLength;

  /// Repeat tracks after the first until the main track ends.
  final bool loopShorter;

  // finish
  final CleanupSettings? cleanup;
  final double volume;

  /// Even out loudness (EBU R128, -16 LUFS).
  final bool normalize;
  final double speed;
  final Duration fadeIn;
  final Duration fadeOut;

  // encode
  final AudioOutputFormat format;
  final AudioQuality quality;
  final bool mono;

  /// Every input, in `-i` order.
  List<AudioSource> get inputs => switch (kind) {
    AudioJobKind.single => [_single!],
    AudioJobKind.merge => sources,
    AudioJobKind.mix => [for (final t in tracks) AudioSource(t.path, t.sourceDuration)],
  };

  /// Whether mix track [index] is looped (never the main track).
  bool loops(int index) =>
      kind == AudioJobKind.mix && loopShorter && index > 0 && mixLength == MixLength.main;

  /// Kept selection [start, end) of a single job, clamped to the source.
  (Duration, Duration) get selection {
    final total = _single?.duration ?? Duration.zero;
    var s = selectionStart ?? Duration.zero;
    var e = selectionEnd ?? total;
    if (e > total) e = total;
    if (s < Duration.zero) s = Duration.zero;
    if (s > e) s = e;
    return (s, e);
  }

  /// Length before the speed change.
  Duration get _baseDuration {
    switch (kind) {
      case AudioJobKind.single:
        final total = _single!.duration;
        final (s, e) = selection;
        return removeSelection ? total - (e - s) : e - s;
      case AudioJobKind.merge:
        var sum = Duration.zero;
        for (final src in sources) {
          sum += src.duration;
        }
        return sources.isEmpty ? sum : sum - effectiveCrossfade * (sources.length - 1);
      case AudioJobKind.mix:
        if (tracks.isEmpty) return Duration.zero;
        if (mixLength == MixLength.main) return tracks.first.end;
        return tracks.map((t) => t.end).reduce((a, b) => a > b ? a : b);
    }
  }

  /// Cross-fade actually used: at most half of the shortest source.
  Duration get effectiveCrossfade {
    if (kind != AudioJobKind.merge || sources.length < 2 || crossfade <= Duration.zero) {
      return Duration.zero;
    }
    final shortest = sources.map((s) => s.duration).reduce((a, b) => a < b ? a : b);
    final cap = shortest ~/ 2;
    return crossfade > cap ? cap : crossfade;
  }

  /// Length of the output file.
  Duration get outputDuration =>
      Duration(microseconds: (_baseDuration.inMicroseconds / speed).round());
}

/// One photo for the image tools: scale to [width]×[height] and encode as
/// [format]. JPG has no transparency, so transparent pixels become white.
class ImageJob {
  const ImageJob({
    required this.input,
    required this.width,
    required this.height,
    required this.format,
    this.quality = 85,
    this.fill = false,
    this.anchorY = 0.5,
    this.dpi,
    this.crop,
  });

  final String input;
  final int width;
  final int height;
  final ImageFormat format;

  /// 1 … 100 (ignored for PNG).
  final int quality;

  /// Crop to exactly [width]×[height] instead of stretching.
  final bool fill;

  /// Vertical crop position for [fill] (0 = top, 0.5 = centre).
  final double anchorY;

  /// Print resolution stored in PNG output.
  final int? dpi;

  /// Part of the source kept before scaling (fractions of the photo).
  final CropRect? crop;
}
