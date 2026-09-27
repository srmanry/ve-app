import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Resolves every directory the app writes to.
///
/// Persistent references (project source media, export files) are stored
/// *relative* to [documents]. On iOS the absolute container path changes on
/// every app update/reinstall, so absolute paths must never be persisted.
class AppPaths {
  AppPaths._(this.documents, this.cache, this.temp, this._userDocuments);

  /// Persistent app data (projects, imported media, exports).
  final Directory documents;

  /// Re-creatable cache (thumbnails).
  final Directory cache;

  /// Scratch space for FFmpeg intermediates. Always safe to wipe when no
  /// job is running.
  final Directory temp;

  static Future<AppPaths> resolve() async {
    final docs = await getApplicationDocumentsDirectory();
    final support = await getApplicationSupportDirectory();
    final cache = await getApplicationCacheDirectory();
    final paths = AppPaths._(
      // Keep app data out of the user-visible Documents folder on iOS; only
      // exports are placed there (see [exportsDir]).
      Directory(p.join(support.path, 'editor_data')),
      Directory(p.join(cache.path, 'editor_cache')),
      Directory(p.join(cache.path, 'editor_tmp')),
      docs,
    );
    for (final dir in [
      paths.documents,
      paths.cache,
      paths.temp,
      paths.mediaDir,
      paths.projectsDir,
      paths.exportsDir,
      paths.thumbnailsDir,
      paths.logosDir,
    ]) {
      await dir.create(recursive: true);
    }
    return paths;
  }

  final Directory _userDocuments;

  /// Imported source media, copied here so picker temp files can be cleared.
  Directory get mediaDir => Directory(p.join(documents.path, 'media'));

  /// One JSON file (+ cover image) per project.
  Directory get projectsDir => Directory(p.join(documents.path, 'projects'));

  /// Exported videos/audio. Lives in the user Documents directory so that on
  /// iOS they are visible in the Files app ("On My iPhone > CutLocal").
  Directory get exportsDir => Directory(p.join(_userDocuments.path, 'Exports'));

  /// User logos for watermarks (kept until the user deletes them).
  Directory get logosDir => Directory(p.join(documents.path, 'logos'));

  Directory get thumbnailsDir => Directory(p.join(cache.path, 'thumbnails'));

  /// Root that relative export paths are stored against.
  Directory get exportsRoot => _userDocuments;

  /// Creates a fresh, unique scratch directory for one processing job.
  Future<Directory> createJobDir(String prefix) async {
    final dir = Directory(p.join(temp.path, '${prefix}_${DateTime.now().microsecondsSinceEpoch}'));
    return dir.create(recursive: true);
  }

  String toRelative(String absolutePath, {Directory? root}) =>
      p.relative(absolutePath, from: (root ?? documents).path);

  String toAbsolute(String relativePath, {Directory? root}) =>
      p.isAbsolute(relativePath) ? relativePath : p.join((root ?? documents).path, relativePath);
}
