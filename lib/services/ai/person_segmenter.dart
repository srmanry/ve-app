import 'package:flutter/services.dart';

import '../../core/errors/app_exception.dart';

/// On-device person segmentation, implemented natively and kept isolated
/// per platform:
///
/// * iOS: Apple Vision `VNGeneratePersonSegmentationRequest` (built into
///   iOS 15+, no download) — `ios/Runner/AppDelegate.swift`.
/// * Android: Google ML Kit Selfie Segmentation with its bundled model —
///   `android/.../PersonSegmentationPlugin.kt`.
///
/// Image pixels never cross the platform channel: the native side reads the
/// frame files and appends 8-bit masks (255 = person) straight to a file.
class PersonSegmenter {
  const PersonSegmenter();

  static const _channel = MethodChannel('app/person_segmentation');

  /// Segments [framePaths] in order, writing one [maskWidth]×[maskHeight]
  /// grayscale mask per frame to [outputPath] (appending when [append]).
  Future<void> segmentFrames({
    required List<String> framePaths,
    required int maskWidth,
    required int maskHeight,
    required String outputPath,
    required bool append,
  }) async {
    try {
      await _channel.invokeMethod<int>('segmentFrames', {
        'framePaths': framePaths,
        'maskWidth': maskWidth,
        'maskHeight': maskHeight,
        'outputPath': outputPath,
        'append': append,
      });
    } on MissingPluginException {
      throw const AppException(
        AppErrorKind.processingFailed,
        'Background removal isn\'t available on this device.',
      );
    } on PlatformException catch (e) {
      if (e.code == 'UNSUPPORTED_DEVICE') {
        throw AppException(
          AppErrorKind.processingFailed,
          'Background removal needs a real phone or tablet — it can\'t run in the simulator.',
          debugDetails: '${e.code}: ${e.message}',
        );
      }
      throw AppException(
        AppErrorKind.processingFailed,
        'Background removal failed on this device.',
        debugDetails: '${e.code}: ${e.message}',
      );
    }
  }
}
