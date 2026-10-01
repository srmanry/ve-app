import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:path/path.dart' as p;

import '../../core/errors/app_exception.dart';
import '../../core/storage/app_paths.dart';
import '../image/image_renderer.dart';
import 'person_segmenter.dart';

/// A person mask: raw 8-bit values and the same as an image (alpha = person).
class PersonMask {
  const PersonMask(this.gray, this.width, this.height, this.image);
  final Uint8List gray;
  final int width;
  final int height;
  final ui.Image image;
}

/// Person mask for a still photo (on device: Vision / ML Kit), as an image
/// whose alpha is the person. Used by background removal and ID photos.
class PhotoCutout {
  const PhotoCutout(this._paths, [this._segmenter = const PersonSegmenter()]);

  final AppPaths _paths;
  final PersonSegmenter _segmenter;

  /// Long side of the mask; enough for smooth edges on a 4K photo.
  static const maskSide = 1024;

  /// Throws [AppException] when no person is found.
  Future<PersonMask> personMask(String photoPath, int width, int height) async {
    final dir = await _paths.createJobDir('photo_mask');
    try {
      final f = math.min(1.0, maskSide / math.max(width, height));
      final mw = math.max(2, (width * f).round());
      final mh = math.max(2, (height * f).round());
      final out = p.join(dir.path, 'mask.gray');
      await _segmenter.segmentFrames(
        framePaths: [photoPath],
        maskWidth: mw,
        maskHeight: mh,
        outputPath: out,
        append: false,
        singleImage: true,
      );
      final gray = await File(out).readAsBytes();
      var any = false;
      for (var i = 0; i < math.min(gray.length, mw * mh); i += 7) {
        if (gray[i] > 128) {
          any = true;
          break;
        }
      }
      if (gray.length < mw * mh || !any) {
        throw const AppException(
          AppErrorKind.processingFailed,
          'No person was found in this photo. Background removal works on photos of people.',
        );
      }
      return PersonMask(gray, mw, mh, await ImageRenderer.maskImage(gray, mw, mh));
    } finally {
      if (await dir.exists()) await dir.delete(recursive: true);
    }
  }
}
