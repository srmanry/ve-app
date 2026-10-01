import 'dart:async';
import 'dart:math' as math;
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
import '../../domain/entities/image_edit.dart';
import '../../domain/entities/exported_media.dart';
import '../../domain/entities/project.dart';
import '../../domain/entities/project_timeline.dart';
import '../../domain/entities/timeline_item.dart';
import '../../domain/repositories/export_repository.dart';
import '../../domain/repositories/media_repository.dart';
import '../ffmpeg/audio_command_builder.dart';
import '../image/pdf_writer.dart';
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

/// [jpeg] with its JFIF density set to [dpi], or null if it has no JFIF
/// header. Layout: `FF D8 FF E0 len(2) 'JFIF\0' version(2) units x(2) y(2)`.
@visibleForTesting
Uint8List? jpegWithDpi(Uint8List jpeg, int dpi) {
  const jfif = [0x4A, 0x46, 0x49, 0x46, 0x00];
  if (jpeg.length < 18 || jpeg[0] != 0xFF || jpeg[1] != 0xD8 || jpeg[2] != 0xFF || jpeg[3] != 0xE0) {
    return null;
  }
  for (var i = 0; i < jfif.length; i++) {
    if (jpeg[6 + i] != jfif[i]) return null;
  }
  final out = Uint8List.fromList(jpeg);
  out[13] = 1; // dots per inch
  out[14] = dpi >> 8;
  out[15] = dpi & 0xFF;
  out[16] = dpi >> 8;
  out[17] = dpi & 0xFF;
  return out;
}

/// Encodes with [encode] (which returns the file size) and, while the file
/// is bigger than [limit], lowers the quality - and, when [canShrink], the
/// dimensions - until it fits. Returns the final (width, height, quality).
///
/// Online forms reject files over their limit, so this tries hard: it
/// jumps close to the right quality first, then shrinks, then squeezes the
/// last bit of quality.
Future<(int, int, int)> encodeWithinLimit({
  required int width,
  required int height,
  required int quality,
  required int? limit,
  required bool canShrink,
  required Future<int> Function(int width, int height, int quality) encode,
}) async {
  var q = quality, w = width, h = height;
  for (var attempt = 0; ; attempt++) {
    final size = await encode(w, h, q);
    if (limit == null || size <= limit || attempt >= 20) break;
    if (q > 35) {
      // Jump close to the right quality, never more than 25 at once.
      final guess = (q * math.sqrt(limit / size)).round();
      q = math.max(35, math.max(q - 25, math.min(q - 5, guess)));
    } else if (canShrink && math.min(w, h) > 120) {
      final k = math.max(0.5, math.min(0.9, math.sqrt(limit / size)));
      w = math.max(2, (w * k).round());
      h = math.max(2, (h * k).round());
    } else if (q > 10) {
      q = math.max(10, q - 8);
    } else {
      break;
    }
  }
  return (w, h, q);
}

/// One photo to save with [ExportService.exportImages].
class ImageExportItem {
  const ImageExportItem({
    required this.input,
    required this.width,
    required this.height,
    required this.baseName,
    this.deleteInput = false,
    this.fill = false,
    this.anchorY = 0.5,
    this.dpi,
    this.maxBytes,
    this.crop,
  });

  /// Absolute path of the source (or an already rendered PNG).
  final String input;

  /// Output size in pixels.
  final int width;
  final int height;
  final String baseName;

  /// [input] is a temporary render that can be deleted afterwards.
  final bool deleteInput;

  /// Crop to exactly [width]×[height] (see [ImageJob.fill]).
  final bool fill;
  final double anchorY;

  /// Print resolution written into JPG / PNG files.
  final int? dpi;

  /// Lower the quality until the file is at most this big (JPG / WebP).
  final int? maxBytes;

  /// Part of the photo to keep (see [ImageJob.crop]).
  final CropRect? crop;
}

/// Progress of [ImageExportJob]: photos finished out of [total].
class ImageExportProgress {
  const ImageExportProgress(this.done, this.total);
  final int done;
  final int total;
  double get fraction => total == 0 ? 0 : done / total;
}

/// A running batch of photo saves. [result] lists what was saved; it throws
/// only when nothing could be saved (or on cancel).
class ImageExportJob {
  ImageExportJob._();

  final _progress = StreamController<ImageExportProgress>.broadcast();
  final _result = Completer<List<ExportedMedia>>();
  bool _cancelled = false;

  Stream<ImageExportProgress> get progress => _progress.stream;
  Future<List<ExportedMedia>> get result => _result.future;

  /// Stops after the current photo.
  void cancel() => _cancelled = true;
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

  /// Audio tools (cut, convert, merge, mix, clean…). [spec] paths are absolute.
  ExportJob exportAudioJob(AudioJob spec, {required String baseName}) {
    final job = ExportJob._();
    unawaited(_runAudioJob(job, spec, baseName));
    return job;
  }

  /// Image tools: scales/encodes each photo as [format] into Exports.
  ImageExportJob exportImages(
    List<ImageExportItem> items, {
    required ImageFormat format,
    int quality = 85,
  }) {
    final job = ImageExportJob._();
    unawaited(_runImages(job, items, format, quality));
    return job;
  }

  Future<void> _runImages(
    ImageExportJob job,
    List<ImageExportItem> items,
    ImageFormat format,
    int quality,
  ) async {
    final saved = <ExportedMedia>[];
    Object? firstError;
    Directory? workDir;
    try {
      // Generous upper bound: uncompressed RGBA of every photo.
      var estimate = 0;
      for (final item in items) {
        estimate += item.width * item.height * (format == ImageFormat.png ? 4 : 1);
      }
      await _checkStorage(estimate);
      workDir = await _paths.createJobDir('images');
      for (var i = 0; i < items.length; i++) {
        if (job._cancelled) break;
        if (!job._progress.isClosed) job._progress.add(ImageExportProgress(i, items.length));
        final item = items[i];
        try {
          final out = File(p.join(workDir.path, 'img_$i.${format.extension}'));
          final (w, h, _) = await encodeWithinLimit(
            width: item.width,
            height: item.height,
            quality: quality,
            limit: format.hasQuality ? item.maxBytes : null,
            canShrink: !item.fill,
            encode: (w, h, q) async {
              await _processing.processImage(
                ImageJob(
                  input: item.input,
                  width: w,
                  height: h,
                  format: format,
                  quality: q,
                  fill: item.fill,
                  anchorY: item.anchorY,
                  dpi: item.dpi,
                  crop: item.crop,
                ),
                out.path,
              );
              if (!await out.exists() || await out.length() == 0) {
                throw const AppException(AppErrorKind.exportFailed, 'The photo couldn\'t be saved.');
              }
              return out.length();
            },
          );
          if (format == ImageFormat.jpg && item.dpi != null) {
            await _setJpegDpi(out, item.dpi!);
          }
          final name = _uniqueName(item.baseName, format.extension);
          final dest = p.join(_paths.exportsDir.path, name);
          try {
            await out.rename(dest);
          } on FileSystemException {
            await out.copy(dest);
          }
          final exported = ExportedMedia(
            id: newId(),
            relativePath: _paths.toRelative(dest, root: _paths.exportsRoot),
            fileName: name,
            createdAt: DateTime.now(),
            duration: Duration.zero,
            sizeBytes: await File(dest).length(),
            width: w,
            height: h,
            isImage: true,
          );
          await _exports.add(exported);
          saved.add(exported);
        } catch (e) {
          debugPrint('Image export failed: $e');
          firstError ??= e;
        } finally {
          if (item.deleteInput) {
            final f = File(item.input);
            if (await f.exists()) await f.delete().catchError((Object _) => f);
          }
        }
      }
      if (!job._progress.isClosed) job._progress.add(ImageExportProgress(items.length, items.length));
    } catch (e) {
      firstError ??= e;
    } finally {
      await _cleanup(workDir);
      await job._progress.close();
      if (saved.isNotEmpty) {
        job._result.complete(saved);
      } else {
        job._result.completeError(
          job._cancelled
              ? AppException.cancelled()
              : AppException.from(
                  firstError ?? AppException.cancelled(),
                  fallbackMessage: 'The photos couldn\'t be saved.',
                ),
        );
      }
    }
  }

  /// Writes [dpi] into the JFIF header so prints come out at the right size.
  static Future<void> _setJpegDpi(File file, int dpi) async {
    try {
      final bytes = await file.readAsBytes();
      final patched = jpegWithDpi(bytes, dpi);
      if (patched != null) await file.writeAsBytes(patched, flush: true);
    } catch (e) {
      debugPrint('Couldn\'t set JPEG DPI: $e');
    }
  }

  /// Scan to PDF: encodes each page (PNG renders) as JPEG and writes one
  /// PDF with an A4 page per image into Exports.
  ImageExportJob exportPdf(List<ImageExportItem> pages, {required String baseName, int quality = 82}) {
    final job = ImageExportJob._();
    unawaited(_runPdf(job, pages, baseName, quality));
    return job;
  }

  Future<void> _runPdf(ImageExportJob job, List<ImageExportItem> pages, String baseName, int quality) async {
    Directory? workDir;
    try {
      if (pages.isEmpty) throw const AppException(AppErrorKind.exportFailed, 'Add at least one page.');
      var estimate = 0;
      for (final pg in pages) {
        estimate += pg.width * pg.height ~/ 4;
      }
      await _checkStorage(estimate);
      workDir = await _paths.createJobDir('pdf');
      final encoded = <PdfPage>[];
      for (var i = 0; i < pages.length; i++) {
        if (job._cancelled) throw AppException.cancelled();
        if (!job._progress.isClosed) job._progress.add(ImageExportProgress(i, pages.length + 1));
        final pg = pages[i];
        final jpg = File(p.join(workDir.path, 'page_$i.jpg'));
        await _processing.processImage(
          ImageJob(input: pg.input, width: pg.width, height: pg.height, format: ImageFormat.jpg, quality: quality),
          jpg.path,
        );
        encoded.add(PdfPage(await jpg.readAsBytes(), pg.width, pg.height));
        await jpg.delete();
      }
      final name = _uniqueName(baseName, 'pdf');
      final dest = File(p.join(_paths.exportsDir.path, name));
      await dest.writeAsBytes(buildPdf(encoded), flush: true);
      final exported = ExportedMedia(
        id: newId(),
        relativePath: _paths.toRelative(dest.path, root: _paths.exportsRoot),
        fileName: name,
        createdAt: DateTime.now(),
        duration: Duration.zero,
        sizeBytes: await dest.length(),
        width: pages.first.width,
        height: pages.first.height,
        isDocument: true,
      );
      await _exports.add(exported);
      if (!job._progress.isClosed) job._progress.add(ImageExportProgress(pages.length + 1, pages.length + 1));
      await job._progress.close();
      job._result.complete([exported]);
    } catch (e) {
      await job._progress.close();
      job._result.completeError(
        job._cancelled ? AppException.cancelled() : AppException.from(e, fallbackMessage: 'The PDF couldn\'t be created.'),
      );
    } finally {
      for (final pg in pages) {
        if (!pg.deleteInput) continue;
        final f = File(pg.input);
        if (await f.exists()) await f.delete().catchError((Object _) => f);
      }
      await _cleanup(workDir);
    }
  }

  Future<void> _runAudioJob(ExportJob job, AudioJob spec, String baseName) async {
    Directory? workDir;
    await _wakelock(true);
    try {
      job._emit(const ExportProgress(ExportStage.preparing, 0));
      if (spec.inputs.isEmpty) {
        throw const AppException(AppErrorKind.exportFailed, 'Add at least one audio file.');
      }
      for (final input in spec.inputs) {
        if (!await File(input.path).exists()) {
          throw AppException.missingSource(p.basename(input.path));
        }
      }
      if (spec.outputDuration <= Duration.zero) {
        throw const AppException(
          AppErrorKind.exportFailed,
          'Nothing would be left of the audio. Change the selection and try again.',
        );
      }
      final seconds = spec.outputDuration.inSeconds + 1;
      await _checkStorage(
        spec.format.hasBitrate
            ? seconds * spec.quality.kbps * 125
            : seconds * AudioCommandBuilder.sampleRate * 4,
      );
      workDir = await _paths.createJobDir('audio');
      final out = File(p.join(workDir.path, 'audio.${spec.format.extension}'));
      await _trackEncoding(job, _processing.processAudio(spec, out.path));
      job._emit(const ExportProgress(ExportStage.finalizing, _encodeEnd));
      job._value = await _finalize(
        rendered: out,
        baseName: baseName,
        extension: spec.format.extension,
        isAudio: true,
      );
    } catch (e, st) {
      final error = job._cancelled
          ? AppException.cancelled()
          : AppException.from(e, fallbackMessage: 'The audio couldn\'t be processed.');
      if (!error.isCancellation) debugPrint('Audio job failed: $e\n$st');
      job._error = error;
    } finally {
      await _cleanup(workDir);
      await job._progress.close();
      await _wakelock(false);
      job._settle();
    }
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
    // The iOS photo picker names copies "image_picker_<UUID>"; that means
    // nothing to people, so call it what it is.
    base = base.replaceFirst(RegExp(r'^image_picker_[0-9A-Fa-f-]+'), 'photo');
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
