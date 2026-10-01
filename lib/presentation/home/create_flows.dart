import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../app/providers.dart';
import '../../core/utils/id_generator.dart';
import '../../domain/entities/logo_placement.dart';
import '../../domain/entities/project.dart';
import '../../domain/entities/project_timeline.dart';
import '../../domain/entities/video_clip.dart';
import '../../domain/usecases/project_usecases.dart';
import '../audio/audio_cut_screen.dart';
import '../audio/audio_merge_screen.dart';
import '../audio/audio_mix_screen.dart';
import '../audio/audio_tool_screen.dart';
import '../camera/record_screen.dart';
import '../image/image_batch_screen.dart';
import '../image/id_photo_screen.dart';
import '../image/image_editor_screen.dart';
import '../image/scan_screen.dart';
import '../image/signature_screen.dart';
import '../editor/editor_screen.dart';
import '../editor/state/editor_state.dart';
import '../export/export_screen.dart';
import '../tools/cut_screen.dart';
import '../tools/merge_screen.dart';
import '../tools/slideshow_screen.dart';
import '../tools/themes_screen.dart';
import '../widgets/app_dialogs.dart';
import '../widgets/media_import_flow.dart';

/// Entry points from Home / quick actions.
class CreateFlows {
  const CreateFlows(this.ref);
  final WidgetRef ref;

  /// Import → new project (saved immediately as a draft) → editor.
  Future<void> createProject(
    BuildContext context, {
    EditorTool? tool,
    bool multiple = true,
    bool allowPhotos = true,
  }) async {
    final added = await importOrRecord(context, ref, multiple: multiple, allowPhotos: allowPhotos);
    if (!context.mounted) return;
    await _openNewProject(context, added, tool: tool);
  }

  /// Opens the in-app camera straight away; takes become a new project.
  Future<void> record(BuildContext context) async {
    final result = await Navigator.of(context).push<RecordResult>(
      MaterialPageRoute(builder: (_) => const RecordScreen(), fullscreenDialog: true),
    );
    if (result == null || result.clips.isEmpty || !context.mounted) return;
    await _openNewProject(context, NewClips(recorded: result.clips, logo: result.logo));
  }

  Future<void> _openNewProject(BuildContext context, NewClips added, {EditorTool? tool}) async {
    if (added.isEmpty) return;
    try {
      final repo = ref.read(projectRepositoryProvider);
      var project = await CreateProject(repo)(
        added.media,
        extraClips: added.recorded,
        exportSettings: ref.read(settingsProvider).defaultExport,
      );
      final logo = added.logo;
      if (logo != null) {
        final timeline = ProjectTimeline(project);
        project = project.copyWith(
          stickerLayers: [
            LogoPlacement.layer(
              id: newId(),
              logoPath: logo.path,
              duration: timeline.duration,
              canvasAspect: timeline.canvasAspectRatio,
              position: logo.position,
              scale: logo.scale,
              opacity: logo.opacity,
            ),
          ],
        );
        await repo.save(project);
      }
      await ref.read(projectsProvider.notifier).refresh();
      if (!context.mounted) return;
      await EditorScreen.open(context, project, tool: tool);
      await ref.read(projectsProvider.notifier).refresh();
    } catch (e) {
      if (context.mounted) await showAppError(context, e);
    }
  }

  /// Own photos and/or videos + a theme + music → styled video.
  /// Opens the theme gallery first; photos/videos are added from there.
  Future<void> themes(BuildContext context) =>
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ThemesScreen()));

  /// Several photos + music → slideshow video.
  Future<void> slideshow(BuildContext context) async {
    final photos = await importPhotos(context, ref);
    if (photos.isEmpty || !context.mounted) return;
    await Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => SlideshowScreen(photos: photos)));
  }

  /// Cut the needed part out of a long video.
  Future<void> cut(BuildContext context) async {
    final media = await importVideos(context, ref, multiple: false);
    if (media.isEmpty || !context.mounted) return;
    await Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => CutScreen(media: media.first)));
  }

  Future<void> merge(BuildContext context) async {
    final media = await importVideos(context, ref);
    if (media.isEmpty || !context.mounted) return;
    await Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => MergeScreen(initial: media)));
  }

  Future<void> videoToAudio(BuildContext context) async {
    final media = await importVideos(context, ref, multiple: false);
    if (media.isEmpty || !context.mounted) return;
    if (!media.first.info.hasAudio) {
      showSnack(context, 'This video has no audio track.');
      return;
    }
    await Navigator.of(context)
        .push(MaterialPageRoute(
          builder: (_) => AudioToolScreen(tool: AudioTool.extract, media: media.first),
        ));
  }

  // ------------------------------------------------------------ audio tools

  /// Convert / compress / clean / volume & speed on one audio file.
  Future<void> audioTool(BuildContext context, AudioTool tool) async {
    final media = await importAudio(context, ref);
    if (media.isEmpty || !context.mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => AudioToolScreen(tool: tool, media: media.first)),
    );
  }

  Future<void> audioCut(BuildContext context) async {
    final media = await importAudio(context, ref);
    if (media.isEmpty || !context.mounted) return;
    await Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => AudioCutScreen(media: media.first)));
  }

  Future<void> audioMerge(BuildContext context) async {
    final media = await importAudio(context, ref, multiple: true);
    if (media.isEmpty || !context.mounted) return;
    await Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => AudioMergeScreen(initial: media)));
  }

  /// Layer tracks ([arrange] = false) or place clips in sequence.
  Future<void> audioMix(BuildContext context, {bool arrange = false}) async {
    final media = await importAudio(context, ref, multiple: true);
    if (media.isEmpty || !context.mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => AudioMixScreen(initial: media, arrange: arrange)),
    );
  }

  /// Compression works on an unsaved single-clip project.
  Future<void> compress(BuildContext context) async {
    final media = await importVideos(context, ref, multiple: false);
    if (media.isEmpty || !context.mounted) return;
    final m = media.first;
    final now = DateTime.now();
    final project = Project(
      id: newId(),
      name: '${p.basenameWithoutExtension(m.displayName)}_compressed',
      createdAt: now,
      updatedAt: now,
      clips: [VideoClip.fromMedia(id: newId(), sourcePath: m.relativePath, media: m.info)],
    );
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ExportScreen(project: project, mode: ExportMode.compress),
      ),
    );
  }

  // ------------------------------------------------------------ image tools

  /// One photo in the editor, opened on [tool].
  Future<void> photoEditor(BuildContext context, PhotoTool tool) async {
    final media = await importPhotosForEditing(context, ref, multiple: false);
    if (media.isEmpty || !context.mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => ImageEditorScreen(media: media.first, initialTool: tool)),
    );
  }

  /// Compress / convert / resize many photos at once.
  Future<void> photoBatch(BuildContext context, ImageBatchTool tool) async {
    final media = await importPhotosForEditing(context, ref);
    if (media.isEmpty || !context.mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => ImageBatchScreen(tool: tool, initial: media)),
    );
  }

  /// Passport / ID photo with a new background and a print sheet.
  Future<void> idPhoto(BuildContext context) async {
    final media = await importPhotosForEditing(context, ref, multiple: false, allowCamera: true);
    if (media.isEmpty || !context.mounted) return;
    await Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => IdPhotoScreen(media: media.first)));
  }

  /// Signature photo → clean, sized for online forms.
  Future<void> signature(BuildContext context) async {
    final media = await importPhotosForEditing(context, ref, multiple: false, allowCamera: true);
    if (media.isEmpty || !context.mounted) return;
    await Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => SignatureScreen(media: media.first)));
  }

  /// Document photos → straightened, cleaned pages → PDF.
  Future<void> scan(BuildContext context) async {
    final media = await importPhotosForEditing(context, ref, allowCamera: true);
    if (media.isEmpty || !context.mounted) return;
    await Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => ScanScreen(initial: media)));
  }
}
