import 'dart:async';

import '../../domain/entities/export_settings.dart';
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
  m4a('M4A (AAC)', 'm4a'),
  wav('WAV', 'wav');

  const AudioOutputFormat(this.label, this.extension);
  final String label;
  final String extension;
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
  });

  final String input;
  final String output;
  final AudioOutputFormat format;
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
