import 'dart:async';
import 'dart:io';

import 'package:ffmpeg_kit_flutter_new_min_gpl/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_min_gpl/ffmpeg_kit_config.dart';
import 'package:ffmpeg_kit_flutter_new_min_gpl/ffmpeg_session.dart';
import 'package:ffmpeg_kit_flutter_new_min_gpl/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new_min_gpl/return_code.dart';
import 'package:ffmpeg_kit_flutter_new_min_gpl/statistics.dart';
import 'package:flutter/foundation.dart';

import '../../core/errors/app_exception.dart';
import '../../domain/entities/media_info.dart';
import '../../domain/entities/project_timeline.dart';
import '../video/video_processing_service.dart';
import 'ffmpeg_command_builder.dart';
import 'ffmpeg_error_mapper.dart';
import 'media_info_parser.dart';

/// [VideoProcessingService] backed by FFmpegKit.
///
/// FFmpegKit runs every command on a native background thread; this class
/// only wires callbacks to Dart streams, so the UI isolate never blocks.
class FfmpegVideoProcessingService implements VideoProcessingService {
  FfmpegVideoProcessingService({FfmpegCommandBuilder? builder})
    : _builder = builder ?? const FfmpegCommandBuilder() {
    // Session objects hold full logs; keep only a handful in memory.
    unawaited(FFmpegKitConfig.setSessionHistorySize(8));
  }

  final FfmpegCommandBuilder _builder;
  final Set<_FfmpegTask> _running = {};

  @override
  Future<MediaInfo> probe(String absolutePath) async {
    final file = File(absolutePath);
    if (!await file.exists()) {
      throw AppException.missingSource(absolutePath.split('/').last);
    }
    final session = await FFprobeKit.getMediaInformation(absolutePath);
    final info = session.getMediaInformation();
    final props = info?.getAllProperties();
    final parsed = props == null
        ? null
        : MediaInfoParser.parse(props, fileSize: await file.length());
    if (parsed != null) return parsed;

    final logs = await session.getAllLogsAsString();
    throw FfmpegErrorMapper.map(
      logs,
      fallbackKind: AppErrorKind.unsupportedVideo,
      fallbackMessage: 'This file isn\'t a supported video or audio file.',
    );
  }

  @override
  Future<void> extractFrame({
    required String input,
    required Duration at,
    required String output,
    int maxWidth = 240,
  }) {
    final task = _start(
      _builder.buildExtractFrame(input: input, at: at, output: output, maxWidth: maxWidth),
      failureMessage: 'Couldn\'t create a thumbnail.',
    );
    return task.done;
  }

  @override
  ProcessingTask render(RenderRequest request) => _start(
    _builder.buildRender(request),
    expectedDuration: ProjectTimeline(request.project).duration,
    failureKind: AppErrorKind.exportFailed,
    failureMessage:
        'The video couldn\'t be exported. Please try again, '
        'or pick a lower resolution.',
  );

  @override
  ProcessingTask extractAudio(AudioExtractRequest request) {
    final duration = request.duration;
    return _start(
      _builder.buildExtractAudio(request),
      expectedDuration: duration == null
          ? null
          : Duration(microseconds: (duration.inMicroseconds / request.speed).round()),
      failureMessage: 'The audio couldn\'t be extracted from this video.',
    );
  }

  @override
  ProcessingTask transcodeForEditing({
    required String input,
    required String output,
    required Duration duration,
  }) => _start(
    _builder.buildEditingProxy(input: input, output: output),
    expectedDuration: duration,
    failureKind: AppErrorKind.unsupportedVideo,
    failureMessage: 'This video couldn\'t be prepared for editing.',
  );

  @override
  ProcessingTask extractSegmentationFrames(BackgroundJob job, String outputPattern) => _start(
    _builder.buildSegmentationFrames(job, outputPattern),
    expectedDuration: job.isStill ? null : job.duration,
    failureMessage: 'The video couldn\'t be prepared for background removal.',
  );

  @override
  ProcessingTask compositeBackground(BackgroundJob job, String masksPath, String output) => _start(
    _builder.buildBackgroundComposite(job, masksPath, output),
    expectedDuration: job.isStill ? null : job.duration,
    failureMessage: 'The background couldn\'t be replaced.',
  );

  @override
  ProcessingTask stabilizeDetect(StabilizeJob job, String transformsPath) => _start(
    _builder.buildStabilizeDetect(job, transformsPath),
    expectedDuration: job.duration,
    failureMessage: 'This video couldn\'t be analysed for stabilization.',
  );

  @override
  ProcessingTask stabilizeTransform(StabilizeJob job, String transformsPath, String output) =>
      _start(
        _builder.buildStabilizeTransform(job, transformsPath, output),
        expectedDuration: job.duration,
        failureMessage: 'The video couldn\'t be stabilized.',
      );

  @override
  Future<void> convertImage({required String input, required String output}) => _start(
    _builder.buildImageToJpeg(input: input, output: output),
    failureKind: AppErrorKind.importFailed,
    failureMessage: 'This photo couldn\'t be imported.',
  ).done;

  @override
  Future<void> cancelAll() async {
    for (final task in _running.toList()) {
      await task.cancel();
    }
  }

  _FfmpegTask _start(
    List<String> args, {
    Duration? expectedDuration,
    AppErrorKind failureKind = AppErrorKind.processingFailed,
    required String failureMessage,
  }) {
    final task = _FfmpegTask(
      args,
      expectedDuration: expectedDuration,
      failureKind: failureKind,
      failureMessage: failureMessage,
    );
    _running.add(task);
    unawaited(
      task.done.then((_) {}, onError: (_) {}).whenComplete(() {
        _running.remove(task);
      }),
    );
    unawaited(task._launch());
    return task;
  }
}

class _FfmpegTask implements ProcessingTask {
  _FfmpegTask(
    this._args, {
    required this.expectedDuration,
    required this.failureKind,
    required this.failureMessage,
  });

  final List<String> _args;
  final Duration? expectedDuration;
  final AppErrorKind failureKind;
  final String failureMessage;

  final _progress = StreamController<ProcessingProgress>.broadcast();
  final _completer = Completer<void>();
  FFmpegSession? _session;
  bool _cancelRequested = false;

  @override
  Stream<ProcessingProgress> get progress => _progress.stream;

  @override
  Future<void> get done => _completer.future;

  Future<void> _launch() async {
    if (kDebugMode) debugPrint('ffmpeg ${_args.join(' ')}');
    try {
      _session = await FFmpegKit.executeWithArgumentsAsync(_args, _onComplete, null, _onStatistics);
      if (_cancelRequested) await _cancelSession();
    } catch (e) {
      _fail(AppException(failureKind, failureMessage, debugDetails: '$e'));
    }
  }

  void _onStatistics(Statistics stats) {
    if (_progress.isClosed) return;
    final processed = Duration(milliseconds: stats.getTime());
    final total = expectedDuration;
    final fraction = total == null || total.inMilliseconds <= 0
        ? null
        : (processed.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0);
    _progress.add(ProcessingProgress(fraction: fraction, processed: processed));
  }

  Future<void> _onComplete(FFmpegSession session) async {
    final code = await session.getReturnCode();
    if (ReturnCode.isSuccess(code)) {
      if (!_completer.isCompleted) _completer.complete();
      await _progress.close();
      return;
    }
    if (_cancelRequested || ReturnCode.isCancel(code)) {
      _fail(AppException.cancelled());
      return;
    }
    final logs = await session.getAllLogsAsString();
    if (kDebugMode) {
      // The error is at the end; the head is just the input listing.
      final lines = (logs ?? '').trimRight().split('\n');
      final tail = lines.skip(lines.length > 25 ? lines.length - 25 : 0).join('\n');
      debugPrint('ffmpeg failed (rc=${code?.getValue()}):\n$tail');
    }
    _fail(FfmpegErrorMapper.map(logs, fallbackKind: failureKind, fallbackMessage: failureMessage));
  }

  void _fail(AppException error) {
    if (!_completer.isCompleted) _completer.completeError(error);
    unawaited(_progress.close());
  }

  @override
  Future<void> cancel() async {
    if (_completer.isCompleted) return;
    _cancelRequested = true;
    await _cancelSession();
  }

  Future<void> _cancelSession() async {
    final id = _session?.getSessionId();
    if (id != null) await FFmpegKit.cancel(id);
  }
}
