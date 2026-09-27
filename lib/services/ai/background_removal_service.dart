import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../core/errors/app_exception.dart';
import '../../core/storage/app_paths.dart';
import '../../domain/entities/video_clip.dart';
import '../../domain/repositories/media_repository.dart';
import '../video/video_processing_service.dart';
import 'person_segmenter.dart';

class BackgroundRemovalProgress {
  const BackgroundRemovalProgress(this.label, this.fraction);
  final String label;
  final double fraction;
}

/// A running background removal. [result] is the new media file.
class BackgroundRemovalJob {
  BackgroundRemovalJob._();

  final _progress = StreamController<BackgroundRemovalProgress>.broadcast();
  final _result = Completer<ImportedMedia>();
  ProcessingTask? _task;
  bool _cancelled = false;

  Stream<BackgroundRemovalProgress> get progress => _progress.stream;
  Future<ImportedMedia> get result => _result.future;

  Future<void> cancel() async {
    _cancelled = true;
    await _task?.cancel();
  }

  void _emit(String label, double f) {
    if (!_progress.isClosed) _progress.add(BackgroundRemovalProgress(label, f));
  }

  void _check() {
    if (_cancelled) throw AppException.cancelled();
  }
}

/// Removes the background behind people in a clip, fully on device:
///
/// 1. FFmpeg writes small frames (15 fps, ≤ 512 px) of the used section.
/// 2. [PersonSegmenter] (Vision / ML Kit) turns each frame into a mask.
/// 3. FFmpeg composites the person over the chosen background at up to
///    1920 px, keeping the original audio.
///
/// The output is a new media file; the source file is untouched.
class BackgroundRemovalService {
  BackgroundRemovalService({
    required this._paths,
    required this._processing,
    required this._media,
    this._segmenter = const PersonSegmenter(),
  });

  final AppPaths _paths;
  final VideoProcessingService _processing;
  final MediaRepository _media;
  final PersonSegmenter _segmenter;

  static const _chunk = 12;

  BackgroundRemovalJob start(VideoClip clip, BackgroundFill fill) {
    final job = BackgroundRemovalJob._();
    unawaited(_run(job, clip, fill));
    return job;
  }

  Future<void> _run(BackgroundRemovalJob job, VideoClip clip, BackgroundFill fill) async {
    Directory? dir;
    ImportedMedia? value;
    Object? error;
    try {
      final input = _media.resolve(clip.sourcePath);
      if (!await File(input).exists()) throw AppException.missingSource(p.basename(input));
      final spec = BackgroundJob(
        input: input,
        isStill: clip.isStill,
        start: clip.trimStart,
        duration: clip.sourceDuration,
        displayWidth: clip.media.displayWidth,
        displayHeight: clip.media.displayHeight,
        fill: fill,
      );
      dir = await _paths.createJobDir('bgremove');
      final framesDir = await Directory(p.join(dir.path, 'frames')).create();

      // 1. Frames.
      job._emit('Reading frames…', 0);
      final extract = _processing.extractSegmentationFrames(
        spec,
        p.join(framesDir.path, '%06d.jpg'),
      );
      job._task = extract;
      final sub = extract.progress.listen(
        (pr) => job._emit('Reading frames…', 0.15 * (pr.fraction ?? 0)),
      );
      try {
        await extract.done;
      } finally {
        await sub.cancel();
      }
      job._check();
      final frames =
          framesDir
              .listSync()
              .whereType<File>()
              .map((f) => f.path)
              .where((path) => path.endsWith('.jpg'))
              .toList()
            ..sort();
      if (frames.isEmpty) {
        throw const AppException(
          AppErrorKind.processingFailed,
          'No frames could be read from this clip.',
        );
      }

      // 2. AI masks, in chunks so progress updates and cancel stay responsive.
      final masks = p.join(dir.path, 'masks.gray');
      for (var i = 0; i < frames.length; i += _chunk) {
        job._check();
        final end = i + _chunk > frames.length ? frames.length : i + _chunk;
        job._emit('Finding people (${i + 1}/${frames.length})…', 0.15 + 0.65 * i / frames.length);
        await _segmenter.segmentFrames(
          framePaths: frames.sublist(i, end),
          maskWidth: spec.maskWidth,
          maskHeight: spec.maskHeight,
          outputPath: masks,
          append: i > 0,
        );
      }
      job._check();

      // 3. Composite.
      job._emit('Replacing background…', 0.8);
      final out = p.join(dir.path, clip.isStill ? 'result.jpg' : 'result.mp4');
      final composite = _processing.compositeBackground(spec, masks, out);
      job._task = composite;
      final sub2 = composite.progress.listen(
        (pr) => job._emit('Replacing background…', 0.8 + 0.18 * (pr.fraction ?? 0)),
      );
      try {
        await composite.done;
      } finally {
        await sub2.cancel();
      }
      job._check();

      job._emit('Finishing…', 0.99);
      value = await _media.adoptGeneratedFile(
        out,
        'Background removed',
        stillSize: clip.isStill ? (width: spec.outputWidth, height: spec.outputHeight) : null,
      );
    } catch (e, st) {
      error = job._cancelled ? AppException.cancelled() : AppException.from(e);
      if (!(error as AppException).isCancellation) debugPrint('Background removal failed: $e\n$st');
    } finally {
      if (dir != null && await dir.exists()) {
        await dir.delete(recursive: true).catchError((Object _) => dir!);
      }
      await job._progress.close();
      if (value != null) {
        job._result.complete(value);
      } else {
        job._result.completeError(error ?? AppException.cancelled());
      }
    }
  }
}
