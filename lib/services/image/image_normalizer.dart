import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

/// Decodes photos with the platform's codecs (JPEG, PNG, WebP, HEIC/HEIF on
/// iOS and Android 9+, GIF first frame), which also applies EXIF orientation,
/// then downsizes them for editing.
///
/// Doing this in Flutter instead of FFmpeg means HEIC photos from phone
/// cameras work, and every photo arrives upright with known dimensions.
class ImageNormalizer {
  const ImageNormalizer();

  /// Longest edge kept. Exports are at most 4K, so larger photos only cost
  /// memory and disk space.
  static const maxSide = 2160;

  /// Writes an upright, downsized PNG of [bytes] to [outputPath].
  /// Throws [FormatException] if the data isn't a decodable image.
  Future<({int width, int height})> toPng(
    Uint8List bytes,
    String outputPath, {
    int maxDimension = ImageNormalizer.maxSide,
  }) async {
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    ui.Codec codec;
    try {
      codec = await ui.instantiateImageCodecWithSize(
        buffer,
        getTargetSize: (w, h) {
          final scale = math.min(1.0, maxDimension / math.max(w, h));
          // Only the width is given so the aspect ratio is always preserved,
          // whatever orientation the decoder applies.
          return ui.TargetImageSize(width: math.max(1, (w * scale).round()));
        },
      );
    } catch (e) {
      buffer.dispose();
      throw FormatException('Undecodable image: $e');
    }
    final frame = await codec.getNextFrame();
    final image = frame.image;
    try {
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      if (png == null) throw const FormatException('PNG encoding failed');
      await File(outputPath).writeAsBytes(png.buffer.asUint8List(), flush: true);
      return (width: image.width, height: image.height);
    } finally {
      image.dispose();
      codec.dispose();
    }
  }
}
