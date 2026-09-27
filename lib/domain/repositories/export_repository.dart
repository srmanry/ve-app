import '../entities/exported_media.dart';

/// Index of files produced by exports.
abstract interface class ExportRepository {
  /// Newest first. Entries whose file no longer exists are dropped.
  Future<List<ExportedMedia>> getAll();

  Future<void> add(ExportedMedia media);

  /// Removes the entry and deletes the file and its thumbnail.
  Future<void> delete(String id);

  /// Absolute path of the exported file.
  String resolvePath(ExportedMedia media);
}
