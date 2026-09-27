import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../../core/constants/app_constants.dart';
import '../../core/errors/app_exception.dart';
import '../../core/storage/app_paths.dart';
import '../../core/storage/device_storage.dart';
import '../../core/utils/id_generator.dart';
import '../../domain/entities/media_info.dart';
import '../../domain/repositories/media_repository.dart';
import '../../services/image/image_normalizer.dart';
import '../../services/video/playback_compatibility.dart';
import '../../services/video/video_processing_service.dart';

/// Imports picked files into app-private storage.
///
/// Why copy? Both platform pickers hand back *temporary* copies (iOS clears
/// them, Android may revoke content-URI access), so projects need a stable
/// file to reference. Copies are streamed file-to-file and never loaded into
/// memory, and unreferenced media is garbage-collected when projects are
/// deleted.
class MediaRepositoryImpl implements MediaRepository {
  MediaRepositoryImpl(
    this._paths,
    this._processing, {
    PlaybackCompatibility? compatibility,
    this._storage = const DeviceStorage(),
  }) : _compatibility = compatibility ?? PlaybackCompatibility.forCurrentPlatform();

  final AppPaths _paths;
  final VideoProcessingService _processing;
  final PlaybackCompatibility _compatibility;
  final DeviceStorage _storage;

  @override
  Future<ImportedMedia> import(
    PickedMedia picked,
    MediaKind kind, {
    void Function(String status)? onStatus,
  }) async {
    if (kind == MediaKind.image) return _importImage(picked, onStatus);
    final ext = _extension(picked.name, kind);
    final id = newId();
    final dest = File(p.join(_paths.mediaDir.path, '$id.$ext'));

    onStatus?.call('Copying file…');
    try {
      await _copyIn(picked, dest);

      onStatus?.call('Reading video info…');
      var info = await _processing.probe(dest.path);
      _validate(info, kind, picked.name);

      if (kind == MediaKind.video && !_compatibility.canPreview(ext, info)) {
        final proxy = File(p.join(_paths.mediaDir.path, '${id}_edit.mp4'));
        await _ensureFreeSpace(info.fileSize * 2);
        final task = _processing.transcodeForEditing(
          input: dest.path,
          output: proxy.path,
          duration: info.duration,
        );
        final sub = task.progress.listen((prog) {
          final pct = prog.fraction == null ? '' : ' ${(prog.fraction! * 100).round()}%';
          onStatus?.call('Converting for editing…$pct');
        });
        try {
          await task.done;
        } catch (_) {
          if (await proxy.exists()) await proxy.delete();
          rethrow;
        } finally {
          await sub.cancel();
        }
        await dest.delete();
        info = await _processing.probe(proxy.path);
        return ImportedMedia(
          relativePath: _paths.toRelative(proxy.path),
          displayName: picked.name,
          info: info,
        );
      }

      return ImportedMedia(
        relativePath: _paths.toRelative(dest.path),
        displayName: picked.name,
        info: info,
      );
    } catch (e) {
      if (await dest.exists()) await dest.delete();
      if (e is AppException) rethrow;
      if (e is FileSystemException) throw _mapFileError(e);
      throw AppException(
        AppErrorKind.importFailed,
        'This file couldn\'t be imported.',
        debugDetails: '$e',
      );
    } finally {
      if (picked.deleteAfterImport && picked.path != null) {
        final tmp = File(picked.path!);
        if (await tmp.exists()) {
          await tmp.delete().catchError((Object _) => tmp);
        }
      }
    }
  }

  /// Photos are decoded and normalised (upright, ≤ 2160 px) by
  /// [ImageNormalizer], then stored as JPEG. They never go through ffprobe:
  /// a photo has no duration of its own.
  Future<ImportedMedia> _importImage(
    PickedMedia picked,
    void Function(String status)? onStatus,
  ) async {
    final id = newId();
    final png = File(p.join(_paths.temp.path, '$id.png'));
    final dest = File(p.join(_paths.mediaDir.path, '$id.jpg'));
    onStatus?.call('Preparing photo…');
    try {
      final Uint8List bytes;
      if (picked.path != null) {
        final source = File(picked.path!);
        if (!await source.exists()) throw AppException.missingSource(picked.name);
        bytes = await source.readAsBytes();
      } else {
        final builder = BytesBuilder(copy: false);
        await for (final chunk in picked.openRead!()) {
          builder.add(chunk);
        }
        bytes = builder.takeBytes();
      }
      await _ensureFreeSpace(bytes.length * 2);

      final ({int width, int height}) size;
      try {
        size = await const ImageNormalizer().toPng(bytes, png.path);
      } on FormatException catch (e) {
        throw AppException(
          AppErrorKind.unsupportedVideo,
          '"${picked.name}" isn\'t a supported photo.',
          debugDetails: '$e',
        );
      }
      await _processing.convertImage(input: png.path, output: dest.path);
      return ImportedMedia(
        relativePath: _paths.toRelative(dest.path),
        displayName: picked.name,
        info: MediaInfo.stillImage(
          width: size.width,
          height: size.height,
          fileSize: await dest.length(),
        ),
      );
    } catch (e) {
      if (await dest.exists()) await dest.delete();
      if (e is AppException) rethrow;
      if (e is FileSystemException) throw _mapFileError(e);
      throw AppException(
        AppErrorKind.importFailed,
        'This photo couldn\'t be imported.',
        debugDetails: '$e',
      );
    } finally {
      if (await png.exists()) await png.delete();
      if (picked.deleteAfterImport && picked.path != null) {
        final tmp = File(picked.path!);
        if (await tmp.exists()) await tmp.delete().catchError((Object _) => tmp);
      }
    }
  }

  Future<void> _copyIn(PickedMedia picked, File dest) async {
    if (picked.path != null) {
      final source = File(picked.path!);
      if (!await source.exists()) throw AppException.missingSource(picked.name);
      await _ensureFreeSpace(await source.length());
      await source.copy(dest.path);
      return;
    }
    final sink = dest.openWrite();
    try {
      await sink.addStream(picked.openRead!());
    } finally {
      await sink.close();
    }
  }

  Future<void> _ensureFreeSpace(int bytes) async {
    final free = await _storage.freeBytes();
    if (free != null && free < bytes + AppConstants.exportStorageSafetyMargin) {
      throw AppException.insufficientStorage(requiredBytes: bytes);
    }
  }

  void _validate(MediaInfo info, MediaKind kind, String name) {
    if (kind == MediaKind.video && !info.hasVideo) {
      throw AppException(AppErrorKind.unsupportedVideo, '"$name" doesn\'t contain a video track.');
    }
    if (kind == MediaKind.video && (info.width <= 0 || info.height <= 0)) {
      throw AppException(
        AppErrorKind.corruptedFile,
        '"$name" couldn\'t be read. The file may be damaged.',
      );
    }
    if (kind == MediaKind.audio && !info.hasAudio) {
      throw AppException(AppErrorKind.unsupportedCodec, '"$name" doesn\'t contain any audio.');
    }
    if (info.duration < AppConstants.minClipDuration) {
      throw AppException(AppErrorKind.unsupportedVideo, '"$name" is too short to edit.');
    }
  }

  String _extension(String name, MediaKind kind) {
    final ext = p.extension(name).replaceFirst('.', '').toLowerCase();
    if (ext.isNotEmpty && ext.length <= 5) return ext;
    return kind == MediaKind.video ? 'mp4' : 'm4a';
  }

  AppException _mapFileError(FileSystemException e) {
    final code = e.osError?.errorCode;
    // ENOSPC = 28 on both Linux (Android) and Darwin (iOS).
    if (code == 28) return AppException.insufficientStorage();
    // EACCES = 13, EPERM = 1.
    if (code == 13 || code == 1) {
      return AppException.permissionDenied('read this file');
    }
    return AppException(
      AppErrorKind.importFailed,
      'This file couldn\'t be imported.',
      debugDetails: '$e',
    );
  }

  @override
  Future<ImportedMedia> adoptGeneratedFile(
    String absolutePath,
    String displayName, {
    ({int width, int height})? stillSize,
  }) async {
    final ext = p.extension(absolutePath).replaceFirst('.', '');
    final dest = p.join(_paths.mediaDir.path, '${newId()}.$ext');
    try {
      await File(absolutePath).rename(dest);
    } on FileSystemException {
      // Different volume: fall back to copy + delete.
      await File(absolutePath).copy(dest);
      await File(absolutePath).delete();
    }
    final info = stillSize == null
        ? await _processing.probe(dest)
        : MediaInfo.stillImage(
            width: stillSize.width,
            height: stillSize.height,
            fileSize: await File(dest).length(),
          );
    return ImportedMedia(
      relativePath: _paths.toRelative(dest),
      displayName: displayName,
      info: info,
    );
  }

  @override
  Future<String> importLogo(PickedMedia picked) async {
    final Uint8List bytes;
    if (picked.path != null) {
      final source = File(picked.path!);
      if (!await source.exists()) throw AppException.missingSource(picked.name);
      bytes = await source.readAsBytes();
    } else {
      final builder = BytesBuilder(copy: false);
      await for (final chunk in picked.openRead!()) {
        builder.add(chunk);
      }
      bytes = builder.takeBytes();
    }
    final dest = File(p.join(_paths.logosDir.path, '${newId()}.png'));
    try {
      // PNG keeps the logo's transparent background.
      await const ImageNormalizer().toPng(bytes, dest.path, maxDimension: 1024);
    } on FormatException catch (e) {
      throw AppException(
        AppErrorKind.unsupportedVideo,
        '"${picked.name}" isn\'t a supported image.',
        debugDetails: '$e',
      );
    } finally {
      if (picked.deleteAfterImport && picked.path != null) {
        final tmp = File(picked.path!);
        if (await tmp.exists()) await tmp.delete().catchError((Object _) => tmp);
      }
    }
    return _paths.toRelative(dest.path);
  }

  @override
  Future<List<String>> listLogos() async {
    final files =
        _paths.logosDir.listSync().whereType<File>().where((f) => f.path.endsWith('.png')).toList()
          ..sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));
    return [for (final f in files) _paths.toRelative(f.path)];
  }

  @override
  Future<void> deleteLogo(String relativePath) async {
    final file = File(resolve(relativePath));
    if (await file.exists()) await file.delete();
  }

  @override
  String resolve(String relativePath) => _paths.toAbsolute(relativePath);

  @override
  Future<bool> exists(String relativePath) => File(resolve(relativePath)).exists();

  @override
  Future<int> deleteUnreferenced(Set<String> inUse) async {
    var deleted = 0;
    await for (final entity in _paths.mediaDir.list()) {
      if (entity is! File) continue;
      if (!inUse.contains(_paths.toRelative(entity.path))) {
        await entity.delete();
        deleted++;
      }
    }
    return deleted;
  }
}
