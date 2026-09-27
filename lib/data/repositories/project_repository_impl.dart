import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../core/storage/app_paths.dart';
import '../../domain/entities/project.dart';
import '../../domain/repositories/project_repository.dart';
import '../datasources/json_file_store.dart';
import '../models/project_json.dart';

/// Stores each project as `projects/<id>.json`, next to its cover image.
class ProjectRepositoryImpl implements ProjectRepository {
  ProjectRepositoryImpl(this._paths);

  final AppPaths _paths;
  final JsonFileStore _store = const JsonFileStore();

  File _file(String id) => File(p.join(_paths.projectsDir.path, '$id.json'));

  @override
  Future<List<Project>> getAll() async {
    final projects = <Project>[];
    await for (final entity in _paths.projectsDir.list()) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      final json = await _store.read(entity);
      if (json == null) continue;
      try {
        projects.add(ProjectJson.decode(json));
      } catch (e) {
        debugPrint('Skipping unreadable project ${entity.path}: $e');
      }
    }
    projects.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return projects;
  }

  @override
  Future<Project?> getById(String id) async {
    final json = await _store.read(_file(id));
    return json == null ? null : ProjectJson.decode(json);
  }

  @override
  Future<void> save(Project project) =>
      _store.write(_file(project.id), ProjectJson.encode(project));

  @override
  Future<void> delete(String id) async {
    final file = _file(id);
    if (await file.exists()) await file.delete();
    final cover = File(p.join(_paths.projectsDir.path, '$id.jpg'));
    if (await cover.exists()) await cover.delete();
  }
}
