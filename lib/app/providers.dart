import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/storage/app_paths.dart';
import '../data/repositories/export_repository_impl.dart';
import '../data/repositories/media_repository_impl.dart';
import '../data/repositories/project_repository_impl.dart';
import '../data/repositories/settings_repository_impl.dart';
import '../domain/entities/app_settings.dart';
import '../domain/entities/exported_media.dart';
import '../domain/entities/project.dart';
import '../domain/repositories/export_repository.dart';
import '../domain/repositories/media_repository.dart';
import '../domain/repositories/project_repository.dart';
import '../domain/repositories/settings_repository.dart';
import '../domain/usecases/project_usecases.dart';
import '../services/ai/background_removal_service.dart';
import '../services/export/export_service.dart';
import '../services/ffmpeg/ffmpeg_video_processing_service.dart';
import '../services/storage/storage_service.dart';
import '../services/thumbnail/thumbnail_service.dart';
import '../services/video/video_processing_service.dart';

// -----------------------------------------------------------------------------
// Infrastructure (overridden in main() once async init is done)
// -----------------------------------------------------------------------------

final appPathsProvider = Provider<AppPaths>(
  (ref) => throw UnimplementedError('Override appPathsProvider in main()'),
);

final sharedPreferencesProvider = Provider<SharedPreferences>(
  (ref) => throw UnimplementedError('Override sharedPreferencesProvider in main()'),
);

/// The processing engine. Swap this single line to replace FFmpeg.
final videoProcessingProvider = Provider<VideoProcessingService>(
  (ref) => FfmpegVideoProcessingService(),
);

// -----------------------------------------------------------------------------
// Repositories & services
// -----------------------------------------------------------------------------

final projectRepositoryProvider = Provider<ProjectRepository>(
  (ref) => ProjectRepositoryImpl(ref.watch(appPathsProvider)),
);

final exportRepositoryProvider = Provider<ExportRepository>(
  (ref) => ExportRepositoryImpl(ref.watch(appPathsProvider)),
);

final mediaRepositoryProvider = Provider<MediaRepository>(
  (ref) => MediaRepositoryImpl(ref.watch(appPathsProvider), ref.watch(videoProcessingProvider)),
);

final settingsRepositoryProvider = Provider<SettingsRepository>(
  (ref) => SettingsRepositoryImpl(ref.watch(sharedPreferencesProvider)),
);

/// True on phones with under ~6 GB RAM (set in main()); heavy work is
/// serialised there to avoid the system's low-memory killer.
final lowMemoryDeviceProvider = Provider<bool>((ref) => false);

final thumbnailServiceProvider = Provider<ThumbnailService>(
  (ref) => ThumbnailService(
    ref.watch(appPathsProvider),
    ref.watch(videoProcessingProvider),
    maxConcurrent: ref.watch(lowMemoryDeviceProvider) ? 1 : 2,
  ),
);

final exportServiceProvider = Provider<ExportService>(
  (ref) => ExportService(
    paths: ref.watch(appPathsProvider),
    processing: ref.watch(videoProcessingProvider),
    exports: ref.watch(exportRepositoryProvider),
    media: ref.watch(mediaRepositoryProvider),
  ),
);

final backgroundRemovalProvider = Provider<BackgroundRemovalService>(
  (ref) => BackgroundRemovalService(
    paths: ref.watch(appPathsProvider),
    processing: ref.watch(videoProcessingProvider),
    media: ref.watch(mediaRepositoryProvider),
  ),
);

final storageServiceProvider = Provider<StorageService>(
  (ref) => StorageService(ref.watch(appPathsProvider)),
);

// -----------------------------------------------------------------------------
// App state
// -----------------------------------------------------------------------------

final settingsProvider = NotifierProvider<SettingsController, AppSettings>(SettingsController.new);

class SettingsController extends Notifier<AppSettings> {
  @override
  AppSettings build() => ref.watch(settingsRepositoryProvider).load();

  Future<void> update(AppSettings Function(AppSettings) change) async {
    state = change(state);
    await ref.read(settingsRepositoryProvider).save(state);
  }
}

final projectsProvider = AsyncNotifierProvider<ProjectsController, List<Project>>(
  ProjectsController.new,
);

class ProjectsController extends AsyncNotifier<List<Project>> {
  ProjectRepository get _repo => ref.read(projectRepositoryProvider);

  @override
  Future<List<Project>> build() => ref.watch(projectRepositoryProvider).getAll();

  Future<void> refresh() async {
    state = AsyncData(await _repo.getAll());
  }

  Future<void> rename(String id, String name) async {
    await RenameProject(_repo)(id, name);
    await refresh();
  }

  Future<Project?> duplicate(String id) async {
    final copy = await DuplicateProject(_repo)(id);
    await refresh();
    return copy;
  }

  Future<void> delete(String id) async {
    await DeleteProject(_repo, ref.read(mediaRepositoryProvider))(id);
    await refresh();
  }
}

final exportsProvider = AsyncNotifierProvider<ExportsController, List<ExportedMedia>>(
  ExportsController.new,
);

class ExportsController extends AsyncNotifier<List<ExportedMedia>> {
  @override
  Future<List<ExportedMedia>> build() => ref.watch(exportRepositoryProvider).getAll();

  Future<void> refresh() async {
    state = AsyncData(await ref.read(exportRepositoryProvider).getAll());
  }

  Future<void> delete(String id) async {
    await ref.read(exportRepositoryProvider).delete(id);
    await refresh();
  }
}
