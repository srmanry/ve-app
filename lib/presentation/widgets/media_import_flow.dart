import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/constants/app_constants.dart';
import '../../core/errors/app_exception.dart';
import '../../domain/entities/logo_placement.dart';
import '../../domain/entities/video_clip.dart';
import '../../domain/repositories/media_repository.dart';
import '../../services/picker/media_picker.dart';
import '../camera/record_screen.dart';
import 'app_dialogs.dart';

final mediaPickerProvider = Provider<MediaPicker>((ref) => MediaPicker());

enum ImportChoice { camera, galleryVideos, galleryPhotos, files }

/// Asks where to import from. With [allowPhotos], photos can be picked too
/// (they become photo clips on the timeline).
Future<ImportChoice?> chooseImportSource(
  BuildContext context, {
  bool allowPhotos = false,
  bool allowCamera = false,
}) => showModalBottomSheet<ImportChoice>(
  context: context,
  builder: (context) => SafeArea(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (allowCamera)
          ListTile(
            leading: const Icon(Icons.videocam_outlined),
            title: const Text('Camera'),
            subtitle: const Text('Record with filters, effects and more'),
            onTap: () => Navigator.pop(context, ImportChoice.camera),
          ),
        ListTile(
          leading: const Icon(Icons.video_library_outlined),
          title: const Text('Videos'),
          subtitle: const Text('From your photo library'),
          onTap: () => Navigator.pop(context, ImportChoice.galleryVideos),
        ),
        if (allowPhotos)
          ListTile(
            leading: const Icon(Icons.photo_library_outlined),
            title: const Text('Photos'),
            subtitle: const Text('Select several photos at once'),
            onTap: () => Navigator.pop(context, ImportChoice.galleryPhotos),
          ),
        ListTile(
          leading: const Icon(Icons.folder_open_outlined),
          title: const Text('Files'),
          subtitle: Text(
            allowPhotos
                ? 'Videos or photos (MP4, MOV, MKV, JPG, PNG…)'
                : 'MP4, MOV, MKV, AVI, WebM…',
          ),
          onTap: () => Navigator.pop(context, ImportChoice.files),
        ),
        const SizedBox(height: 8),
      ],
    ),
  ),
);

/// Full import flow: source choice, system picker, copy/probe with
/// progress, friendly errors. Returns successfully imported media. With
/// [allowPhotos], the result may contain photos (`info.isStillImage`).
Future<List<ImportedMedia>> importVideos(
  BuildContext context,
  WidgetRef ref, {
  bool multiple = true,
  bool allowPhotos = false,
  ImportChoice? choice,
}) async {
  choice ??= await chooseImportSource(context, allowPhotos: allowPhotos);
  if (choice == null || choice == ImportChoice.camera || !context.mounted) return const [];
  final selected = choice;
  final picker = ref.read(mediaPickerProvider);
  final picked = await _pick(context, () async {
    switch (selected) {
      case ImportChoice.camera:
        return const <PickedMedia>[];
      case ImportChoice.galleryVideos:
        return picker.pickVideos(PickSource.gallery, multiple: multiple);
      case ImportChoice.galleryPhotos:
        return picker.pickImages(PickSource.gallery);
      case ImportChoice.files:
        return allowPhotos
            ? picker.pickVisualFiles()
            : picker.pickVideos(PickSource.files, multiple: multiple);
    }
  });
  if (picked.isEmpty || !context.mounted) return const [];
  return _importAll(context, ref, picked, null);
}

/// Picks several photos (gallery or files) for a slideshow.
Future<List<ImportedMedia>> importPhotos(BuildContext context, WidgetRef ref) async {
  final source = await showModalBottomSheet<PickSource>(
    context: context,
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.photo_library_outlined),
            title: const Text('Gallery'),
            subtitle: const Text('Select several photos at once'),
            onTap: () => Navigator.pop(context, PickSource.gallery),
          ),
          ListTile(
            leading: const Icon(Icons.folder_open_outlined),
            title: const Text('Files'),
            subtitle: const Text('JPG, PNG, HEIC, WebP…'),
            onTap: () => Navigator.pop(context, PickSource.files),
          ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
  if (source == null || !context.mounted) return const [];
  final picked = await _pick(context, () => ref.read(mediaPickerProvider).pickImages(source));
  if (picked.isEmpty || !context.mounted) return const [];
  return _importAll(context, ref, picked, MediaKind.image);
}

Future<List<ImportedMedia>> importAudio(BuildContext context, WidgetRef ref) async {
  final picked = await _pick(context, () => ref.read(mediaPickerProvider).pickAudio());
  if (picked.isEmpty || !context.mounted) return const [];
  return _importAll(context, ref, picked, MediaKind.audio);
}

Future<List<PickedMedia>> _pick(
  BuildContext context,
  Future<List<PickedMedia>> Function() pick,
) async {
  try {
    return await pick();
  } on PlatformException catch (e) {
    if (!context.mounted) return const [];
    final denied = e.code.contains('denied') || e.code.contains('access');
    await showAppError(
      context,
      denied
          ? AppException.permissionDenied('access your media')
          : AppException(
              AppErrorKind.importFailed,
              'The picker couldn\'t be opened.',
              debugDetails: '$e',
            ),
    );
    return const [];
  }
}

Future<List<ImportedMedia>> _importAll(
  BuildContext context,
  WidgetRef ref,
  List<PickedMedia> picked,
  MediaKind? kind,
) async {
  final repo = ref.read(mediaRepositoryProvider);
  final imported = <ImportedMedia>[];
  final failures = <AppException>[];

  await runWithProgress(context, (status) async {
    for (var i = 0; i < picked.length; i++) {
      final prefix = picked.length > 1 ? '(${i + 1}/${picked.length}) ' : '';
      try {
        // Without an explicit kind (mixed picks), photos are told apart by name.
        final itemKind =
            kind ?? (isImageFileName(picked[i].name) ? MediaKind.image : MediaKind.video);
        imported.add(
          await repo.import(picked[i], itemKind, onStatus: (s) => status.value = '$prefix$s'),
        );
      } catch (e) {
        failures.add(AppException.from(e));
      }
    }
  }, initialStatus: 'Importing…');

  if (!context.mounted) return imported;
  if (failures.isNotEmpty) {
    final first = failures.first;
    await showAppError(
      context,
      failures.length == 1 || picked.length == 1
          ? first
          : AppException(
              first.kind,
              '${failures.length} of ${picked.length} files couldn\'t be imported. ${first.message}',
            ),
    );
  }
  final large = imported.any(
    (m) =>
        m.info.fileSize > AppConstants.largeFileBytes ||
        m.info.width * m.info.height >= AppConstants.largeVideoPixels,
  );
  if (large && context.mounted) {
    showSnack(context, 'Large video detected - preview and export may take longer.');
  }
  return imported;
}

/// New main-track material: imported files and/or clips recorded in the
/// in-app camera (which already carry their filter/effect/speed).
class NewClips {
  const NewClips({this.media = const [], this.recorded = const [], this.logo});
  final List<ImportedMedia> media;
  final List<VideoClip> recorded;

  /// Logo chosen in the camera, to lay over [recorded].
  final CameraLogo? logo;

  bool get isEmpty => media.isEmpty && recorded.isEmpty;
}

/// Source sheet with Camera / Videos / Photos / Files.
Future<NewClips> importOrRecord(
  BuildContext context,
  WidgetRef ref, {
  bool multiple = true,
  bool allowPhotos = true,
}) async {
  final choice = await chooseImportSource(context, allowPhotos: allowPhotos, allowCamera: true);
  if (choice == null || !context.mounted) return const NewClips();
  if (choice == ImportChoice.camera) {
    final result = await Navigator.of(context).push<RecordResult>(
      MaterialPageRoute(builder: (_) => const RecordScreen(), fullscreenDialog: true),
    );
    return NewClips(recorded: result?.clips ?? const [], logo: result?.logo);
  }
  final media = await importVideos(
    context,
    ref,
    multiple: multiple,
    allowPhotos: allowPhotos,
    choice: choice,
  );
  return NewClips(media: media);
}
