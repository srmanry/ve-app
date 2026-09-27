import '../../core/utils/id_generator.dart';
import '../entities/export_settings.dart';
import '../entities/project.dart';
import '../entities/video_clip.dart';
import '../repositories/media_repository.dart';
import '../repositories/project_repository.dart';

/// Creates and saves a new project from imported videos.
class CreateProject {
  const CreateProject(this._projects);
  final ProjectRepository _projects;

  Future<Project> call(
    List<ImportedMedia> videos, {
    List<VideoClip> extraClips = const [],
    String? name,
    ExportSettings exportSettings = const ExportSettings(),
  }) async {
    final now = DateTime.now();
    final project = Project(
      id: newId(),
      name: name ?? _defaultName(now),
      createdAt: now,
      updatedAt: now,
      exportSettings: exportSettings,
      clips: [
        for (final v in videos)
          VideoClip.fromMedia(id: newId(), sourcePath: v.relativePath, media: v.info),
        ...extraClips,
      ],
    );
    await _projects.save(project);
    return project;
  }

  static String _defaultName(DateTime t) {
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    final mm = t.minute.toString().padLeft(2, '0');
    return 'Project ${months[t.month - 1]} ${t.day}, ${t.hour}:$mm';
  }
}

class RenameProject {
  const RenameProject(this._projects);
  final ProjectRepository _projects;

  Future<Project?> call(String id, String newName) async {
    final name = newName.trim();
    if (name.isEmpty) return null;
    final project = await _projects.getById(id);
    if (project == null) return null;
    final renamed = project.copyWith(name: name, updatedAt: DateTime.now());
    await _projects.save(renamed);
    return renamed;
  }
}

/// Duplicates metadata only; both projects reference the same media files.
class DuplicateProject {
  const DuplicateProject(this._projects);
  final ProjectRepository _projects;

  Future<Project?> call(String id) async {
    final source = await _projects.getById(id);
    if (source == null) return null;
    final now = DateTime.now();
    final copy = source.copyWith(
      id: newId(),
      name: '${source.name} (copy)',
      createdAt: now,
      updatedAt: now,
    );
    await _projects.save(copy);
    return copy;
  }
}

/// Deletes a project and any imported media no other project references.
class DeleteProject {
  const DeleteProject(this._projects, this._media);
  final ProjectRepository _projects;
  final MediaRepository _media;

  Future<void> call(String id) async {
    await _projects.delete(id);
    await CollectUnusedMedia(_projects, _media)();
  }
}

/// Removes imported media that no saved project references.
///
/// Only safe when no editor session is open (unsaved edits may reference
/// media that isn't saved in any project yet).
class CollectUnusedMedia {
  const CollectUnusedMedia(this._projects, this._media);
  final ProjectRepository _projects;
  final MediaRepository _media;

  Future<int> call() async {
    final all = await _projects.getAll();
    final inUse = {for (final p in all) ...p.referencedMedia};
    return _media.deleteUnreferenced(inUse);
  }
}
