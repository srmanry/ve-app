import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gal/gal.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/theme/app_theme.dart';
import '../../app/providers.dart';
import '../../core/constants/app_constants.dart';
import '../../core/errors/app_exception.dart';
import '../../core/permissions/gallery_permission.dart';
import '../../domain/entities/exported_media.dart';
import '../widgets/app_dialogs.dart';
import 'player_screen.dart';

/// Actions available on an exported file (used by the export result and
/// the Exported Videos screen).
class ExportActions {
  ExportActions(this.ref);
  final WidgetRef ref;

  String pathOf(ExportedMedia media) =>
      ref.read(exportRepositoryProvider).resolvePath(media);

  Future<void> play(BuildContext context, ExportedMedia media) {
    final loaded = ref.read(exportsProvider).value ?? const <ExportedMedia>[];
    final mediaList = loaded.any((item) => item.id == media.id)
        ? loaded
        : [media, ...loaded];
    final initialIndex = mediaList.indexWhere((item) => item.id == media.id);
    final playlist = mediaList
        .map(
          (item) => PlayerItem(
            path: pathOf(item),
            title: item.fileName,
            audioOnly: item.isAudioOnly,
          ),
        )
        .toList(growable: false);

    return Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PlayerScreen(
          path: pathOf(media),
          title: media.fileName,
          audioOnly: media.isAudioOnly,
          playlist: playlist,
          initialIndex: initialIndex,
        ),
      ),
    );
  }

  Future<void> share(BuildContext context, ExportedMedia media) async {
    final box = context.findRenderObject() as RenderBox?;
    try {
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(pathOf(media))],
          sharePositionOrigin: box == null
              ? null
              : box.localToGlobal(Offset.zero) & box.size,
        ),
      );
    } catch (e) {
      if (context.mounted) {
        await showAppError(
          context,
          AppException(
            AppErrorKind.unknown,
            'Sharing failed.',
            debugDetails: '$e',
          ),
        );
      }
    }
  }

  Future<void> saveToGallery(BuildContext context, ExportedMedia media) async {
    if (media.isAudioOnly) {
      showSnack(
        context,
        'Audio files can\'t go in the photo gallery - use Share instead.',
      );
      return;
    }
    try {
      await const GalleryPermission().ensureCanSave();
      await Gal.putVideo(pathOf(media), album: AppConstants.appName);
      if (context.mounted) showSnack(context, 'Saved to your gallery');
    } on GalException catch (e) {
      if (!context.mounted) return;
      await showAppError(context, switch (e.type) {
        GalExceptionType.accessDenied => AppException.permissionDenied(
          'save to your gallery',
        ),
        GalExceptionType.notEnoughSpace => AppException.insufficientStorage(),
        _ => AppException(
          AppErrorKind.unknown,
          'The video couldn\'t be saved to the gallery.',
          debugDetails: '$e',
        ),
      });
    } catch (e) {
      if (context.mounted) await showAppError(context, e);
    }
  }

  /// iOS: opens the Files app at the exports folder (visible under
  /// "On My iPhone"). Android: shows the location and opens the file with
  /// an external app.
  Future<void> openLocation(BuildContext context, ExportedMedia media) async {
    final path = pathOf(media);
    if (Platform.isIOS) {
      final uri = Uri.parse('shareddocuments://${p.dirname(path)}');
      if (await launchUrl(uri)) return;
    }
    if (!context.mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'File location',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              SelectableText(path, style: const TextStyle(fontSize: 12)),
              const SizedBox(height: 8),
              Text(
                Platform.isAndroid
                    ? 'This folder is private to the app. Use "Save" to copy the video to your gallery, '
                          'or open it with another app.'
                    : 'Find it in the Files app under On My iPhone › ${AppConstants.appName} › Exports.',
                style: TextStyle(fontSize: 12, color: context.mutedColor),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                icon: const Icon(Icons.open_in_new),
                label: const Text('Open with…'),
                onPressed: () async {
                  Navigator.pop(context);
                  final result = await OpenFilex.open(path);
                  if (result.type != ResultType.done && context.mounted) {
                    showSnack(context, 'No app found to open this file.');
                  }
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<bool> delete(BuildContext context, ExportedMedia media) async {
    final ok = await confirm(
      context,
      title: 'Delete export?',
      message: '"${media.fileName}" will be permanently deleted.',
    );
    if (!ok) return false;
    await ref.read(exportsProvider.notifier).delete(media.id);
    return true;
  }
}
