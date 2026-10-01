import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gal/gal.dart';
import 'package:share_plus/share_plus.dart';

import '../../app/providers.dart';
import '../../core/constants/app_constants.dart';
import '../../core/errors/app_exception.dart';
import '../../core/permissions/gallery_permission.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/formatters.dart';
import '../../domain/entities/exported_media.dart';
import '../../domain/entities/image_edit.dart';
import '../../services/export/export_service.dart';
import '../editor/panels/panel_common.dart';
import '../exports/export_actions.dart';
import '../widgets/app_dialogs.dart';

/// Format & quality pickers for photo output.
class ImageFormatOptions extends StatelessWidget {
  const ImageFormatOptions({
    super.key,
    required this.format,
    required this.quality,
    required this.onFormat,
    required this.onQuality,
    this.transparent = false,
  });

  final ImageFormat format;
  final int quality;
  final ValueChanged<ImageFormat> onFormat;
  final ValueChanged<int> onQuality;

  /// The image has transparent areas (warn for JPG).
  final bool transparent;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      const Text('Format', style: TextStyle(fontWeight: FontWeight.w600)),
      const SizedBox(height: 8),
      ChipRow<ImageFormat>(
        values: ImageFormat.values,
        selected: format,
        label: (f) => f.label,
        onSelected: onFormat,
      ),
      const SizedBox(height: 4),
      Text(
        transparent && !format.keepsTransparency
            ? 'JPG has no transparency - the background becomes white.'
            : format.hint,
        style: TextStyle(
          fontSize: 12,
          color: transparent && !format.keepsTransparency
              ? Theme.of(context).colorScheme.error
              : context.mutedColor,
        ),
      ),
      if (format.hasQuality) ...[
        const SizedBox(height: 14),
        Row(
          children: [
            const Text('Quality', style: TextStyle(fontWeight: FontWeight.w600)),
            const Spacer(),
            Text('$quality%', style: const TextStyle(fontWeight: FontWeight.w600)),
          ],
        ),
        Slider(
          value: quality.toDouble(),
          min: 10,
          max: 100,
          divisions: 18,
          label: '$quality%',
          onChanged: (v) => onQuality(v.round()),
        ),
        Text(
          quality >= 90
              ? 'Best quality, larger file'
              : quality >= 70
              ? 'Great quality, much smaller (recommended)'
              : 'Smallest file, visible loss on close look',
          style: TextStyle(fontSize: 12, color: context.mutedColor),
        ),
      ],
    ],
  );
}

/// Asks for format/quality, renders via [render] (returns a temporary PNG
/// path) and saves it to Exports, then shows the result.
Future<void> showImageSaveSheet(
  BuildContext context,
  WidgetRef ref, {
  required String baseName,
  required bool transparent,
  required (int, int) outputSize,
  required Future<String> Function() render,
  int originalBytes = 0,
}) async {
  var format = transparent ? ImageFormat.png : ImageFormat.jpg;
  var quality = 85;
  final go = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    builder: (context) => StatefulBuilder(
      builder: (context, setSheet) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Save photo', style: Theme.of(context).textTheme.titleMedium),
              Text(
                '${outputSize.$1} × ${outputSize.$2} px',
                style: TextStyle(fontSize: 12, color: context.mutedColor),
              ),
              const SizedBox(height: 16),
              ImageFormatOptions(
                format: format,
                quality: quality,
                transparent: transparent,
                onFormat: (f) => setSheet(() => format = f),
                onQuality: (q) => setSheet(() => quality = q),
              ),
              const SizedBox(height: 18),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(48),
                    textStyle: const TextStyle(fontFamily: 'Poppins', fontWeight: FontWeight.w600),
                  ),
                  onPressed: () => Navigator.pop(context, true),
                  icon: const Icon(Icons.save_alt_rounded),
                  label: const Text('Save'),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  if (go != true || !context.mounted) return;

  final List<ExportedMedia> saved;
  try {
    saved = await runWithProgress(context, (status) async {
      status.value = 'Rendering…';
      final input = await render();
      status.value = 'Saving…';
      final job = ref.read(exportServiceProvider).exportImages(
        [
          ImageExportItem(
            input: input,
            width: outputSize.$1,
            height: outputSize.$2,
            baseName: baseName,
            deleteInput: true,
          ),
        ],
        format: format,
        quality: quality,
      );
      return job.result;
    }, initialStatus: 'Rendering…');
  } catch (e) {
    if (context.mounted) await showAppError(context, e);
    return;
  }
  await ref.read(exportsProvider.notifier).refresh();
  if (context.mounted) await showImageResults(context, ref, saved, originalBytes: originalBytes);
}

/// Saved photos with Open / Share / Save to gallery.
Future<void> showImageResults(
  BuildContext context,
  WidgetRef ref,
  List<ExportedMedia> saved, {
  int originalBytes = 0,
  int failed = 0,
}) {
  final actions = ExportActions(ref);
  final total = saved.fold<int>(0, (sum, m) => sum + m.sizeBytes);
  return showModalBottomSheet<void>(
    context: context,
    builder: (context) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.check_circle_rounded, color: Color(0xFF10B981), size: 44),
            const SizedBox(height: 6),
            Text(
              saved.length == 1 ? saved.first.fileName : '${saved.length} photos saved',
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 2),
            Text(
              [
                if (saved.length == 1) '${saved.first.width} × ${saved.first.height}',
                Formatters.fileSize(total),
                if (originalBytes > 0)
                  'was ${Formatters.fileSize(originalBytes)}'
                      '${total < originalBytes ? ' (${(100 - total * 100 / originalBytes).round()}% smaller)' : ''}',
              ].join(' · '),
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12.5, color: context.mutedColor),
            ),
            if (failed > 0)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  '$failed photo${failed == 1 ? '' : 's'} couldn\'t be saved.',
                  style: TextStyle(fontSize: 12.5, color: Theme.of(context).colorScheme.error),
                ),
              ),
            const SizedBox(height: 14),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                PanelAction(
                  icon: Icons.image_outlined,
                  label: 'Open',
                  onTap: () => actions.play(context, saved.first),
                ),
                Builder(
                  builder: (context) => PanelAction(
                    icon: Icons.ios_share_rounded,
                    label: 'Share',
                    onTap: () => _shareAll(context, actions, saved),
                  ),
                ),
                PanelAction(
                  icon: Icons.photo_library_outlined,
                  label: 'Gallery',
                  onTap: () => _saveAll(context, actions, saved),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text('Also kept in Exports.', style: TextStyle(fontSize: 11.5, color: context.mutedColor)),
          ],
        ),
      ),
    ),
  );
}

Future<void> _shareAll(BuildContext context, ExportActions actions, List<ExportedMedia> saved) async {
  final box = context.findRenderObject() as RenderBox?;
  try {
    await SharePlus.instance.share(
      ShareParams(
        files: [for (final m in saved) XFile(actions.pathOf(m))],
        sharePositionOrigin: box == null ? null : box.localToGlobal(Offset.zero) & box.size,
      ),
    );
  } catch (e) {
    if (context.mounted) {
      await showAppError(context, AppException(AppErrorKind.unknown, 'Sharing failed.', debugDetails: '$e'));
    }
  }
}

Future<void> _saveAll(BuildContext context, ExportActions actions, List<ExportedMedia> saved) async {
  try {
    await const GalleryPermission().ensureCanSave();
    for (final m in saved) {
      if (!File(actions.pathOf(m)).existsSync()) continue;
      await Gal.putImage(actions.pathOf(m), album: AppConstants.appName);
    }
    if (context.mounted) {
      showSnack(context, saved.length == 1 ? 'Saved to your gallery' : '${saved.length} photos saved to your gallery');
    }
  } on GalException catch (e) {
    if (!context.mounted) return;
    await showAppError(
      context,
      e.type == GalExceptionType.accessDenied
          ? AppException.permissionDenied('save to your gallery')
          : AppException(AppErrorKind.unknown, 'The photos couldn\'t be saved to the gallery.', debugDetails: '$e'),
    );
  } catch (e) {
    if (context.mounted) await showAppError(context, e);
  }
}
