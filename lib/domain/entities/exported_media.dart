/// A file produced by an export (video) or by the Video-to-Audio tool.
class ExportedMedia {
  const ExportedMedia({
    required this.id,
    required this.relativePath,
    required this.fileName,
    required this.createdAt,
    required this.duration,
    required this.sizeBytes,
    this.width = 0,
    this.height = 0,
    this.isAudioOnly = false,
    this.thumbnailPath,
    this.projectId,
  });

  final String id;

  /// Relative to the user documents directory (see `AppPaths.exportsRoot`).
  final String relativePath;
  final String fileName;
  final DateTime createdAt;
  final Duration duration;
  final int sizeBytes;
  final int width;
  final int height;
  final bool isAudioOnly;

  /// Relative to the app data directory.
  final String? thumbnailPath;
  final String? projectId;

  ExportedMedia copyWith({String? fileName, String? relativePath}) => ExportedMedia(
    id: id,
    relativePath: relativePath ?? this.relativePath,
    fileName: fileName ?? this.fileName,
    createdAt: createdAt,
    duration: duration,
    sizeBytes: sizeBytes,
    width: width,
    height: height,
    isAudioOnly: isAudioOnly,
    thumbnailPath: thumbnailPath,
    projectId: projectId,
  );
}
