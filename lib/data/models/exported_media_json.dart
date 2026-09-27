import '../../domain/entities/exported_media.dart';

abstract final class ExportedMediaJson {
  static Map<String, Object?> encode(ExportedMedia m) => {
    'id': m.id,
    'path': m.relativePath,
    'fileName': m.fileName,
    'createdAt': m.createdAt.toIso8601String(),
    'durationUs': m.duration.inMicroseconds,
    'sizeBytes': m.sizeBytes,
    'width': m.width,
    'height': m.height,
    'audioOnly': m.isAudioOnly,
    'thumbnail': m.thumbnailPath,
    'projectId': m.projectId,
  };

  static ExportedMedia decode(Map<String, Object?> j) => ExportedMedia(
    id: j['id'] as String,
    relativePath: j['path'] as String,
    fileName: (j['fileName'] as String?) ?? 'Export',
    createdAt: DateTime.tryParse((j['createdAt'] as String?) ?? '') ?? DateTime.now(),
    duration: Duration(microseconds: (j['durationUs'] as num?)?.toInt() ?? 0),
    sizeBytes: (j['sizeBytes'] as num?)?.toInt() ?? 0,
    width: (j['width'] as num?)?.toInt() ?? 0,
    height: (j['height'] as num?)?.toInt() ?? 0,
    isAudioOnly: (j['audioOnly'] as bool?) ?? false,
    thumbnailPath: j['thumbnail'] as String?,
    projectId: j['projectId'] as String?,
  );
}
