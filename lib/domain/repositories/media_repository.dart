import '../entities/media_info.dart';

/// A media file that has been copied into app storage and probed.
class ImportedMedia {
  const ImportedMedia({required this.relativePath, required this.displayName, required this.info});

  final String relativePath;
  final String displayName;
  final MediaInfo info;
}

/// Something the user picked, before import. Either a local [path] or a
/// byte stream (Android content URIs without a file path).
class PickedMedia {
  const PickedMedia({required this.name, this.path, this.openRead, this.deleteAfterImport = false})
    : assert(path != null || openRead != null);

  final String name;
  final String? path;
  final Stream<List<int>> Function()? openRead;

  /// True when [path] is a temporary copy made by the picker.
  final bool deleteAfterImport;
}

enum MediaKind { video, audio, image }

abstract interface class MediaRepository {
  /// Copies [picked] into app storage (streamed; never loaded fully into
  /// memory), probes it and validates it is usable as [kind].
  ///
  /// [onStatus] receives human-readable progress ("Copying…", "Converting…").
  Future<ImportedMedia> import(
    PickedMedia picked,
    MediaKind kind, {
    void Function(String status)? onStatus,
  });

  /// Imports a photo for the image tools: upright, kept as lossless PNG up
  /// to [ImageToolsLimits.maxSide] px. `info.fileSize` is the original
  /// file's size (for before/after comparisons).
  Future<ImportedMedia> importPhotoForEditing(
    PickedMedia picked, {
    void Function(String status)? onStatus,
  });

  /// Stores an already-produced file (e.g. extracted audio) in media storage.
  ///
  /// Pass [stillSize] for generated photos (they have no duration to probe).
  Future<ImportedMedia> adoptGeneratedFile(
    String absolutePath,
    String displayName, {
    ({int width, int height})? stillSize,
  });

  /// Stores a logo/watermark image as PNG (transparency kept, ≤ 1024 px)
  /// in the logo library, which is never garbage-collected.
  Future<String> importLogo(PickedMedia picked);

  /// Saved logos (relative paths), newest first.
  Future<List<String>> listLogos();

  Future<void> deleteLogo(String relativePath);

  String resolve(String relativePath);

  Future<bool> exists(String relativePath);

  /// Deletes media files not referenced by any of [inUse].
  Future<int> deleteUnreferenced(Set<String> inUse);
}

abstract final class ImageToolsLimits {
  /// Longest side kept by the image tools (memory-safe on 3-4 GB phones).
  static const maxSide = 4096;
}
