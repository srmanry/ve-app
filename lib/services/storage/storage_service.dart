import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../core/storage/app_paths.dart';

class StorageUsage {
  const StorageUsage({
    required this.exportsBytes,
    required this.projectDataBytes,
    required this.mediaBytes,
    required this.cacheBytes,
    required this.tempBytes,
  });

  final int exportsBytes;

  /// Project JSON files, covers and export thumbnails.
  final int projectDataBytes;

  /// Imported source media referenced by projects.
  final int mediaBytes;

  /// Timeline thumbnail cache.
  final int cacheBytes;

  /// FFmpeg scratch files.
  final int tempBytes;

  int get totalBytes => exportsBytes + projectDataBytes + mediaBytes + cacheBytes + tempBytes;
}

/// Reports disk usage and clears re-creatable files.
class StorageService {
  StorageService(this._paths);

  final AppPaths _paths;

  Future<StorageUsage> usage() async {
    final data = await _dirSize(_paths.documents);
    final media = await _dirSize(_paths.mediaDir);
    return StorageUsage(
      exportsBytes: await _dirSize(_paths.exportsDir),
      projectDataBytes: data - media,
      mediaBytes: media,
      cacheBytes: await _dirSize(_paths.thumbnailsDir),
      tempBytes: await _dirSize(_paths.temp),
    );
  }

  /// Deletes FFmpeg scratch files, picker copies and the thumbnail cache.
  /// Must not be called while an export is running.
  Future<void> clearTemporaryFiles({bool includeThumbnails = true}) async {
    await _emptyDir(_paths.temp);
    if (includeThumbnails) await _emptyDir(_paths.thumbnailsDir);
    try {
      await FilePicker.clearTemporaryFiles();
    } catch (e) {
      debugPrint('FilePicker cleanup failed: $e');
    }
  }

  Future<void> _emptyDir(Directory dir) async {
    if (!await dir.exists()) return;
    await for (final entity in dir.list()) {
      try {
        await entity.delete(recursive: true);
      } catch (e) {
        debugPrint('Could not delete ${p.basename(entity.path)}: $e');
      }
    }
  }

  static Future<int> _dirSize(Directory dir) async {
    if (!await dir.exists()) return 0;
    var total = 0;
    try {
      await for (final entity in dir.list(recursive: true, followLinks: false)) {
        if (entity is File) {
          try {
            total += await entity.length();
          } on FileSystemException {
            // File vanished mid-scan.
          }
        }
      }
    } on FileSystemException {
      // Directory vanished mid-scan.
    }
    return total;
  }
}
