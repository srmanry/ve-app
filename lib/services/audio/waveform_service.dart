import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../core/storage/app_paths.dart';
import '../video/video_processing_service.dart';

/// Draws audio as bars: FFmpeg decodes to low-rate mono PCM, then the peaks
/// are computed in a background isolate. Results are cached per file.
class WaveformService {
  WaveformService(this._paths, this._processing);

  final AppPaths _paths;
  final VideoProcessingService _processing;
  final _cache = <String, Future<List<double>>>{};

  static const buckets = 220;

  /// Peaks 0 … 1 (normalised to the loudest), [buckets] long.
  Future<List<double>> peaks(String absolutePath, Duration duration) =>
      _cache.putIfAbsent(absolutePath, () async {
        try {
          return await _load(absolutePath, duration);
        } catch (_) {
          _cache.removeWhere((key, _) => key == absolutePath);
          rethrow;
        }
      });

  Future<List<double>> _load(String path, Duration duration) async {
    final dir = await _paths.createJobDir('wave');
    try {
      // Keep the decoded data to a few MB even for hour-long files.
      final seconds = math.max(1, duration.inSeconds);
      final rate = (4000000 / seconds).clamp(200, 8000).round();
      final out = p.join(dir.path, 'pcm.raw');
      await _processing.decodePcm(input: path, output: out, sampleRate: rate).done;
      final bytes = await File(out).readAsBytes();
      return await compute(computePeaks, bytes);
    } finally {
      if (await dir.exists()) await dir.delete(recursive: true);
    }
  }
}

/// RMS per bucket of little-endian 16-bit PCM, normalised to the loudest.
@visibleForTesting
List<double> computePeaks(Uint8List bytes) {
  final samples = bytes.buffer.asInt16List(bytes.offsetInBytes, bytes.lengthInBytes ~/ 2);
  if (samples.isEmpty) return List.filled(WaveformService.buckets, 0);
  final out = List<double>.filled(WaveformService.buckets, 0);
  final per = samples.length / WaveformService.buckets;
  var loudest = 0.0;
  for (var b = 0; b < WaveformService.buckets; b++) {
    final from = (b * per).floor();
    final to = math.max(from + 1, ((b + 1) * per).floor()).clamp(0, samples.length);
    var sum = 0.0;
    for (var i = from; i < to; i++) {
      final v = samples[i] / 32768;
      sum += v * v;
    }
    final rms = to > from ? math.sqrt(sum / (to - from)) : 0.0;
    out[b] = rms;
    if (rms > loudest) loudest = rms;
  }
  if (loudest <= 0) return out;
  return [for (final v in out) v / loudest];
}
