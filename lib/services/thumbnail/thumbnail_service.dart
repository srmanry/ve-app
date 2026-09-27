import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../core/storage/app_paths.dart';
import '../../core/utils/stable_hash.dart';
import '../video/video_processing_service.dart';

/// Generates video frame thumbnails on demand with a persistent disk cache.
///
/// Designed for long timelines:
/// * frames are extracted one at a time with fast input seeking - the video
///   is never decoded in full;
/// * timestamps are quantised so zooming reuses cached frames;
/// * requests are served newest-first (LIFO) with a bounded queue, so frames
///   for the part of the timeline the user just scrolled to come first and
///   stale requests are dropped;
/// * only [maxConcurrent] extractions run at once.
class ThumbnailService {
  ThumbnailService(this._paths, this._processing, {this.maxConcurrent = 2});

  final AppPaths _paths;
  final VideoProcessingService _processing;

  /// Parallel extractions (1 on low-memory phones).
  final int maxConcurrent;
  static const maxQueued = 48;

  final _inFlight = <String, Future<File?>>{};
  final _queue = ListQueue<_Request>();
  var _running = 0;

  /// Quantisation step (ms) for timestamps.
  static const quantumMs = 250;

  String _key(String path, Duration at, int width) =>
      stableHash('$path|${at.inMilliseconds ~/ quantumMs}|$width');

  File _fileFor(String key) => File(p.join(_paths.thumbnailsDir.path, '$key.jpg'));

  /// Returns the cached thumbnail immediately if present.
  File? cached(String absolutePath, Duration at, {int width = 160}) {
    final file = _fileFor(_key(absolutePath, at, width));
    return file.existsSync() ? file : null;
  }

  /// Returns a JPEG thumbnail for [absolutePath] at [at], or null if it
  /// couldn't be produced (e.g. request dropped or unreadable file).
  Future<File?> frame(String absolutePath, Duration at, {int width = 160}) {
    final key = _key(absolutePath, at, width);
    final existing = _inFlight[key];
    if (existing != null) return existing;

    final file = _fileFor(key);
    if (file.existsSync()) return Future.value(file);

    final completer = Completer<File?>();
    _inFlight[key] = completer.future;
    _queue.addFirst(_Request(key, absolutePath, at, width, file, completer));
    while (_queue.length > maxQueued) {
      final dropped = _queue.removeLast();
      _inFlight.remove(dropped.key);
      dropped.completer.complete(null);
    }
    _pump();
    return completer.future;
  }

  void _pump() {
    while (_running < maxConcurrent && _queue.isNotEmpty) {
      final req = _queue.removeFirst();
      _running++;
      unawaited(
        _extract(req).whenComplete(() {
          _running--;
          _inFlight.remove(req.key);
          _pump();
        }),
      );
    }
  }

  Future<void> _extract(_Request req) async {
    final tmp = File('${req.file.path}.part.jpg');
    try {
      await _processing.extractFrame(
        input: req.path,
        at: Duration(milliseconds: (req.at.inMilliseconds ~/ quantumMs) * quantumMs),
        output: tmp.path,
        maxWidth: req.width,
      );
      if (await tmp.exists() && await tmp.length() > 0) {
        await tmp.rename(req.file.path);
        req.completer.complete(req.file);
      } else {
        req.completer.complete(null);
      }
    } catch (e) {
      debugPrint('Thumbnail failed for ${req.path}@${req.at}: $e');
      if (await tmp.exists()) await tmp.delete();
      req.completer.complete(null);
    }
  }

  /// Writes a cover image (larger) to [output].
  Future<bool> cover(String absolutePath, Duration at, String output) async {
    try {
      await _processing.extractFrame(input: absolutePath, at: at, output: output, maxWidth: 480);
      return File(output).existsSync();
    } catch (e) {
      debugPrint('Cover failed: $e');
      return false;
    }
  }
}

class _Request {
  _Request(this.key, this.path, this.at, this.width, this.file, this.completer);
  final String key;
  final String path;
  final Duration at;
  final int width;
  final File file;
  final Completer<File?> completer;
}
