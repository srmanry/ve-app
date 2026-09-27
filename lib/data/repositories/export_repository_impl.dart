import 'dart:io';

import 'package:path/path.dart' as p;

import '../../core/storage/app_paths.dart';
import '../../domain/entities/exported_media.dart';
import '../../domain/repositories/export_repository.dart';
import '../datasources/json_file_store.dart';
import '../models/exported_media_json.dart';

/// Keeps an index (`exports.json`) of exported files.
class ExportRepositoryImpl implements ExportRepository {
  ExportRepositoryImpl(this._paths);

  final AppPaths _paths;
  final JsonFileStore _store = const JsonFileStore();

  File get _index => File(p.join(_paths.documents.path, 'exports.json'));

  Future<List<ExportedMedia>> _readIndex() async {
    final json = await _store.read(_index);
    final items = json?['items'];
    if (items is! List) return [];
    return items
        .whereType<Map<dynamic, dynamic>>()
        .map((m) => ExportedMediaJson.decode(m.cast<String, Object?>()))
        .toList();
  }

  Future<void> _writeIndex(List<ExportedMedia> items) =>
      _store.write(_index, {'items': items.map(ExportedMediaJson.encode).toList()});

  @override
  Future<List<ExportedMedia>> getAll() async {
    final items = await _readIndex();
    final existing = <ExportedMedia>[];
    for (final item in items) {
      if (await File(resolvePath(item)).exists()) existing.add(item);
    }
    if (existing.length != items.length) await _writeIndex(existing);
    existing.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return existing;
  }

  @override
  Future<void> add(ExportedMedia media) async {
    final items = await _readIndex();
    await _writeIndex([media, ...items.where((i) => i.id != media.id)]);
  }

  @override
  Future<void> delete(String id) async {
    final items = await _readIndex();
    final target = items.where((i) => i.id == id).firstOrNull;
    if (target != null) {
      final file = File(resolvePath(target));
      if (await file.exists()) await file.delete();
      final thumb = target.thumbnailPath;
      if (thumb != null) {
        final thumbFile = File(_paths.toAbsolute(thumb));
        if (await thumbFile.exists()) await thumbFile.delete();
      }
    }
    await _writeIndex(items.where((i) => i.id != id).toList());
  }

  @override
  String resolvePath(ExportedMedia media) =>
      _paths.toAbsolute(media.relativePath, root: _paths.exportsRoot);
}
