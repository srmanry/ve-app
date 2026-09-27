import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../../app/providers.dart';
import '../../core/utils/formatters.dart';
import '../../domain/entities/exported_media.dart';
import 'export_actions.dart';

class ExportedMediaTile extends ConsumerWidget {
  const ExportedMediaTile({super.key, required this.media});
  final ExportedMedia media;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final actions = ExportActions(ref);
    final paths = ref.read(appPathsProvider);
    final thumb = media.thumbnailPath == null ? null : File(paths.toAbsolute(media.thumbnailPath!));

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => actions.play(context, media),
          child: Row(
            children: [
              SizedBox(
                width: 96,
                height: 64,
                child: thumb != null && thumb.existsSync()
                    ? Image.file(thumb, fit: BoxFit.cover, cacheWidth: 200)
                    : ColoredBox(
                        color: const Color(0xFF232838),
                        child: Icon(
                          media.isAudioOnly ? Icons.audiotrack : Icons.movie_outlined,
                          color: context.mutedColor,
                        ),
                      ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      media.fileName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      [
                        if (!media.isAudioOnly) '${media.width}×${media.height}',
                        Formatters.duration(media.duration),
                        Formatters.fileSize(media.sizeBytes),
                      ].join(' · '),
                      style: TextStyle(fontSize: 11, color: context.mutedColor),
                    ),
                    Text(
                      Formatters.date(media.createdAt),
                      style: TextStyle(fontSize: 11, color: context.mutedColor),
                    ),
                  ],
                ),
              ),
              Builder(
                builder: (context) => PopupMenuButton<String>(
                  onSelected: (v) {
                    switch (v) {
                      case 'play':
                        actions.play(context, media);
                      case 'share':
                        actions.share(context, media);
                      case 'save':
                        actions.saveToGallery(context, media);
                      case 'location':
                        actions.openLocation(context, media);
                      case 'delete':
                        actions.delete(context, media);
                    }
                  },
                  itemBuilder: (_) => [
                    const PopupMenuItem(value: 'play', child: Text('Play')),
                    const PopupMenuItem(value: 'share', child: Text('Share')),
                    if (!media.isAudioOnly)
                      const PopupMenuItem(value: 'save', child: Text('Save to gallery')),
                    const PopupMenuItem(value: 'location', child: Text('File location')),
                    const PopupMenuItem(value: 'delete', child: Text('Delete')),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
