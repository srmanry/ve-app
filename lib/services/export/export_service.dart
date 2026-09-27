import 'dart:async';
import 'dart:io';
import 'dart:ui' show Size;

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../core/constants/app_constants.dart';
import '../../core/errors/app_exception.dart';
import '../../core/storage/app_paths.dart';
import '../../core/storage/device_storage.dart';
import '../../core/utils/id_generator.dart';
import '../../domain/entities/export_settings.dart';
import '../../domain/entities/exported_media.dart';
import '../../domain/entities/project.dart';
import '../../domain/entities/project_timeline.dart';
import '../../domain/entities/timeline_item.dart';
import '../../domain/repositories/export_repository.dart';
import '../../domain/repositories/media_repository.dart';
import '../overlay/overlay_painter.dart';
import '../video/video_processing_service.dart';

enum ExportStage {
  preparing('Preparing…'),
  renderingOverlays('Rendering text & stickers…'),
  encoding('Encoding video & audio…'),
  finalizing('Finalizing…');

  const ExportStage(this.label);
  final String label;
}

class ExportProgress {
  const ExportProgress(this.stage, this.fraction, {this.remaining});

  final ExportStage stage;

  /// Overall progress 0 … 1.
  final double fraction;

  /// Estimated time left, when enough data is available.
  final Duration? remaining;
}

/// A running export. [result] throws `AppException` (kind `cancelled` after
/// [cancel]); temp files are always cleaned up.
class ExportJob {
  ExportJob._();

  final _progress = StreamController<ExportProgress>.broadcast();
  final _result = Completer<ExportedMedia>();
  ProcessingTask? _task;
  bool _cancelled = false;

  // Outcome is recorded first and delivered by [_settle] only after temp
  // files are cleaned up, so callers never observe leftovers.
  ExportedMedia? _value;
  Object? _error;

  void _settle() {
    if (_result.isCompleted) return;
    if (_value != null) {
      _result.complete(_value);
    } else {
      _result.completeError(_error ?? AppException.cancelled());
    }
  }

  Stream<ExportProgress> get progress => _progress.stream;
  Future<ExportedMedia> get result => _result.future;

  Future<void> cancel() async {
    _cancelled = true;
    await _task?.cancel();
  }

  void _emit(ExportProgress p) {
    if (!_progress.isClosed) _progress.add(p);
  }

  void _checkCancelled() {
    if (_cancelled) throw AppException.cancelled();
  }
}

/// Orchestrates exports: validation, storage checks, overlay rasterisation,
/// encoding via [VideoProcessingService], moving the result into the
/// exports folder and indexing it.
class ExportService {
  ExportService({
    required this._paths,
    required this._processing,
    required this._exports,
    required this._media,
    this._storage = const DeviceStorage(),
  });

  final AppPaths _paths;
  final VideoProcessingService _processing;
  final ExportRepository _exports;
  final MediaRepository _media;
  final DeviceStorage _storage;

  // Stage weights for the overall progress bar.
  static const _prepareEnd = 0.03;
  static const _overlaysEnd = 0.08;
  static const _encodeEnd = 0.97;

  ExportJob exportProject(Project project, ExportSettings settings) {
    final job = ExportJob._();
    unawaited(_runProject(job, project, settings));
    return job;
  }

  /// Video-to-Audio tool.
  ExportJob exportAudio({
    required String sourceRelativePath,
    required String displayName,
    required AudioOutputFormat format,
    required Duration duration,
  }) {
    final job = ExportJob._();
    unawaited(_runAudio(job, sourceRelativePath, displayName, format, duration));
    return job;
  }

  Future<void> _runProject(ExportJob job, Project project, ExportSettings settings) async {
    // Platform shape/fit overrides apply to this export only.
    project = project.copyWith(canvas: settings.canvasFor(project.canvas));
    Directory? workDir;
    File? output;
    await _wakelock(true);
    try {
      job._emit(const ExportProgress(ExportStage.preparing, 0));
      if (project.clips.isEmpty) {
        throw const AppException(
          AppErrorKind.exportFailed,
          'Add at least one video clip before exporting.',
        );
      }
      for (final path in project.referencedMedia) {
        if (!await _media.exists(path)) {
          throw const AppException(
            AppErrorKind.missingSourceFile,
            'A video or audio file used in this project is missing. '
            'Remove it from the timeline and try again.',
          );
        }
      }
      final timeline = ProjectTimeline(project);
      await _checkStorage(timeline.estimateOutputBytes(settings));
      workDir = await _paths.createJobDir('export');
      job._checkCancelled();

      // Rasterise text & stickers at output resolution.
      final size = timeline.outputSize(settings);
      final canvas = Size(size.width.toDouble(), size.height.toDouble());
      final layers = <TimelineItem>[
        ...project.textLayers,
        ...project.stickerLayers,
      ].where((l) => l.start < timeline.duration && l.duration > Duration.zero).toList();
      final overlays = <OverlayImage>[];
      for (var i = 0; i < layers.length; i++) {
        job._checkCancelled();
        job._emit(
          ExportProgress(
            ExportStage.renderingOverlays,
            _prepareEnd + (_overlaysEnd - _prepareEnd) * i / layers.length,
          ),
        );
        final png = await OverlayPainter.rasterize(layers[i], canvas, resolveImage: _media.resolve);
        final file = File(p.join(workDir.path, 'overlay_$i.png'));
        await file.writeAsBytes(png, flush: true);
        overlays.add(
          OverlayImage(
            path: file.path,
            start: layers[i].start,
            end: layers[i].end > timeline.duration ? timeline.duration : layers[i].end,
          ),
        );
      }

      output = File(p.join(workDir.path, 'render.mp4'));
      final task = _processing.render(
        RenderRequest(
          project: project,
          settings: settings,
          resolveMedia: _media.resolve,
          outputPath: output.path,
          overlays: overlays,
        ),
      );
      await _trackEncoding(job, task);

      job._emit(const ExportProgress(ExportStage.finalizing, _encodeEnd));
      final exported = await _finalize(
        rendered: output,
        baseName: project.name,
        extension: 'mp4',
        isAudio: false,
        projectId: project.id,
      );
      job._emit(const ExportProgress(ExportStage.finalizing, 1));
      job._value = exported;
    } catch (e, st) {
      final error = job._cancelled
          ? AppException.cancelled()
          : AppException.from(e, fallbackMessage: 'The export failed. Please try again.');
      if (!error.isCancellation) debugPrint('Export failed: $e\n$st');
      job._error = error;
    } finally {
      await _cleanup(workDir);
      await job._progress.close();
      await _wakelock(false);
      job._settle();
    }
  }

  Future<void> _runAudio(
    ExportJob job,
    String source,
    String displayName,
    AudioOutputFormat format,
    Duration duration,
  ) async {
    Directory? workDir;
    await _wakelock(true);
    try {
      job._emit(const ExportProgress(ExportStage.preparing, 0));
      if (!await _media.exists(source)) throw AppException.missingSource(displayName);
      // WAV is ~10 MB/min; AAC far less. Use the WAV rate as an upper bound.
      await _checkStorage((duration.inSeconds + 1) * 48000 * 4);
      workDir = await _paths.createJobDir('audio');
      final out = File(p.join(workDir.path, 'audio.${format.extension}'));
      final task = _processing.extractAudio(
        AudioExtractRequest(
          input: _media.resolve(source),
          output: out.path,
          format: format,
          duration: duration,
        ),
      );
      await _trackEncoding(job, task);
      job._emit(const ExportProgress(ExportStage.finalizing, _encodeEnd));
      final exported = await _finalize(
        rendered: out,
        baseName: p.basenameWithoutExtension(displayName),
        extension: format.extension,
        isAudio: true,
      );
      job._value = exported;
    } catch (e) {
      job._error = (job._cancelled
          ? AppException.cancelled()
          : AppException.from(e, fallbackMessage: 'The audio couldn\'t be extracted.'));
    } finally {
      await _cleanup(workDir);
      await job._progress.close();
      await _wakelock(false);
      job._settle();
    }
  }

  Future<void> _trackEncoding(ExportJob job, ProcessingTask task) async {
    job._task = task;
    job._checkCancelled();
    final started = DateTime.now();
    final sub = task.progress.listen((prog) {
      final f = prog.fraction ?? 0;
      Duration? remaining;
      final elapsed = DateTime.now().difference(started);
      // Only estimate once we have a stable rate.
      if (f > 0.03 && elapsed.inSeconds >= 2) {
        remaining = Duration(milliseconds: (elapsed.inMilliseconds * (1 - f) / f).round());
      }
      job._emit(
        ExportProgress(
          ExportStage.encoding,
          _overlaysEnd + (_encodeEnd - _overlaysEnd) * f,
          remaining: remaining,
        ),
      );
    });
    try {
      await task.done;
    } finally {
      await sub.cancel();
    }
  }

  Future<ExportedMedia> _finalize({
    required File rendered,
    required String baseName,
    required String extension,
    required bool isAudio,
    String? projectId,
  }) async {
    if (!await rendered.exists() || await rendered.length() == 0) {
      throw const AppException(
        AppErrorKind.exportFailed,
        'The export didn\'t produce a file. Please try again.',
      );
    }
    final name = _uniqueName(baseName, extension);
    final dest = p.join(_paths.exportsDir.path, name);
    try {
      await rendered.rename(dest);
    } on FileSystemException {
      await rendered.copy(dest);
    }

    final info = await _processing.probe(dest);
    String? thumbRelative;
    if (!isAudio) {
      final thumbDir = Directory(p.join(_paths.documents.path, 'export_thumbs'));
      await thumbDir.create(recursive: true);
      final thumb = p.join(thumbDir.path, '${p.basenameWithoutExtension(name)}.jpg');
      final at = info.duration > const Duration(seconds: 2)
          ? const Duration(seconds: 1)
          : Duration.zero;
      try {
        await _processing.extractFrame(input: dest, at: at, output: thumb, maxWidth: 360);
        thumbRelative = _paths.toRelative(thumb);
      } catch (e) {
        debugPrint('Export thumbnail failed: $e');
      }
    }

    final exported = ExportedMedia(
      id: newId(),
      relativePath: _paths.toRelative(dest, root: _paths.exportsRoot),
      fileName: name,
      createdAt: DateTime.now(),
      duration: info.duration,
      sizeBytes: await File(dest).length(),
      width: info.displayWidth,
      height: info.displayHeight,
      isAudioOnly: isAudio,
      thumbnailPath: thumbRelative,
      projectId: projectId,
    );
    await _exports.add(exported);
    return exported;
  }

  String _uniqueName(String base, String ext) {
    final safe = base.replaceAll(RegExp(r'[^\w\- ]+'), '').trim().replaceAll(RegExp(r'\s+'), '_');
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final stamp =
        '${now.year}${two(now.month)}${two(now.day)}_'
        '${two(now.hour)}${two(now.minute)}${two(now.second)}';
    var name = '${safe.isEmpty ? 'video' : safe}_$stamp.$ext';
    var n = 1;
    while (File(p.join(_paths.exportsDir.path, name)).existsSync()) {
      name = '${safe.isEmpty ? 'video' : safe}_${stamp}_${n++}.$ext';
    }
    return name;
  }

  Future<void> _checkStorage(int estimatedBytes) async {
    final free = await _storage.freeBytes();
    // Output is written to temp then moved (same volume), so ~1x is enough
    // plus a safety margin for FFmpeg buffers and overlays.
    final needed = (estimatedBytes * 1.2).round() + AppConstants.exportStorageSafetyMargin;
    if (free != null && free < needed) {
      throw AppException.insufficientStorage(requiredBytes: needed);
    }
  }

  Future<void> _cleanup(Directory? dir) async {
    if (dir == null) return;
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (e) {
      debugPrint('Failed to clean $dir: $e');
    }
  }

  Future<void> _wakelock(bool on) async {
    try {
      await WakelockPlus.toggle(enable: on);
    } catch (_) {
      // Not critical.
    }
  }
}
