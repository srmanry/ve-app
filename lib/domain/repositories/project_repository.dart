import '../entities/project.dart';

/// Persistence for projects. Implementations must store only metadata and
/// media *references*, never the media itself.
abstract interface class ProjectRepository {
  /// All projects, most recently edited first.
  Future<List<Project>> getAll();

  Future<Project?> getById(String id);

  Future<void> save(Project project);

  Future<void> delete(String id);
}
