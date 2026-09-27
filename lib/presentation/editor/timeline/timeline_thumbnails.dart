import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../domain/entities/video_clip.dart';

/// Thumbnail strip for a clip. Only tiles inside the visible window are
/// built; each tile loads its frame lazily through the cached
/// `ThumbnailService`.
class TimelineThumbnails extends ConsumerWidget {
  const TimelineThumbnails({
    super.key,
    required this.clip,
    required this.pps,
    required this.height,
    required this.visibleStart,
    required this.visibleEnd,
  });

  final VideoClip clip;
  final double pps;
  final double height;
  final Duration visibleStart;
  final Duration visibleEnd;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final media = ref.read(mediaRepositoryProvider);
    final path = media.resolve(clip.sourcePath);
    final tileWidth = (height * clip.media.aspectRatio).clamp(32.0, 100.0);
    final clipWidth = clip.duration.inMicroseconds / 1e6 * pps;
    final tileCount = math.max(1, (clipWidth / tileWidth).ceil());

    final firstVisible = math.max(0, (visibleStart.inMicroseconds / 1e6 * pps / tileWidth).floor());
    final lastVisible = math.min(
      tileCount - 1,
      (visibleEnd.inMicroseconds / 1e6 * pps / tileWidth).ceil(),
    );

    final tiles = <Widget>[];
    for (var i = firstVisible; i <= lastVisible; i++) {
      final localSec = (i + 0.5) * tileWidth / pps;
      final local = Duration(microseconds: (localSec * 1e6).round());
      final source = clip.localToSource(local > clip.duration ? clip.duration : local);
      final Widget tile = clip.isStill
          ? Image.file(
              File(path),
              fit: BoxFit.cover,
              cacheWidth: 160,
              gaplessPlayback: true,
              filterQuality: FilterQuality.low,
            )
          : _ThumbTile(path: path, at: source);
      tiles.add(
        Positioned(left: i * tileWidth, top: 0, width: tileWidth, height: height, child: tile),
      );
    }
    return Stack(clipBehavior: Clip.hardEdge, children: tiles);
  }
}

class _ThumbTile extends ConsumerStatefulWidget {
  const _ThumbTile({required this.path, required this.at});
  final String path;
  final Duration at;

  @override
  ConsumerState<_ThumbTile> createState() => _ThumbTileState();
}

class _ThumbTileState extends ConsumerState<_ThumbTile> {
  File? _file;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(_ThumbTile old) {
    super.didUpdateWidget(old);
    if (old.path != widget.path || old.at != widget.at) _load();
  }

  void _load() {
    final service = ref.read(thumbnailServiceProvider);
    final cached = service.cached(widget.path, widget.at);
    if (cached != null) {
      _file = cached;
      return;
    }
    final at = widget.at;
    service.frame(widget.path, at).then((file) {
      if (mounted && widget.at == at && file != null) setState(() => _file = file);
    });
  }

  @override
  Widget build(BuildContext context) {
    final file = _file;
    if (file == null) return const ColoredBox(color: Color(0xFF232838));
    return Image.file(
      file,
      fit: BoxFit.cover,
      cacheWidth: 160,
      gaplessPlayback: true,
      filterQuality: FilterQuality.low,
      errorBuilder: (_, _, _) => const ColoredBox(color: Color(0xFF232838)),
    );
  }
}
