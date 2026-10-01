/// A file produced by an export (video), the audio tools or the image tools.
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
    this.isImage = false,
    this.isDocument = false,
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

  /// A photo from the image tools (no duration, not playable).
  final bool isImage;

  /// A PDF from Scan to PDF (opened in another app).
  final bool isDocument;

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
    isImage: isImage,
    isDocument: isDocument,
    thumbnailPath: thumbnailPath,
    projectId: projectId,
  );
}
