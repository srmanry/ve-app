import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../../domain/entities/canvas_settings.dart';
import '../../../domain/entities/video_clip.dart';
import '../../../services/video/color_matrix.dart';

/// Renders one clip (a video player, or the photo for still clips) with the clip's crop, rotation, flip and colour
/// matrix applied, fitted into the parent box according to [fit].
///
/// Transform order matches the FFmpeg chain: crop → rotate → flip → colour.
class ClipVideoView extends StatelessWidget {
  const ClipVideoView({
    super.key,
    required this.clip,
    this.controller,
    this.stillPath,
    required this.fit,
    this.showCrop = true,
    this.showGeometry = true,
  });

  final VideoClip clip;
  final VideoPlayerController? controller;

  /// Absolute path of the photo for still clips.
  final String? stillPath;
  final CanvasFit fit;

  /// Crop editing shows the uncropped, unrotated frame.
  final bool showCrop;
  final bool showGeometry;

  @override
  Widget build(BuildContext context) {
    final dw = clip.media.displayWidth.toDouble().clamp(1.0, 100000.0);
    final dh = clip.media.displayHeight.toDouble().clamp(1.0, 100000.0);

    assert(controller != null || stillPath != null);
    final Widget source = controller != null
        ? VideoPlayer(controller!)
        : Image.file(
            File(stillPath!),
            fit: BoxFit.fill,
            gaplessPlayback: true,
            // Photos are stored at ≤ 2160 px; decode at preview-friendly size.
            cacheWidth: 1280,
          );
    Widget content = SizedBox(width: dw, height: dh, child: source);

    if (showCrop && !clip.crop.isFull) {
      final c = clip.crop;
      content = SizedBox(
        width: dw * c.width,
        height: dh * c.height,
        child: ClipRect(
          child: OverflowBox(
            alignment: Alignment.topLeft,
            minWidth: dw,
            maxWidth: dw,
            minHeight: dh,
            maxHeight: dh,
            child: Transform.translate(offset: Offset(-c.left * dw, -c.top * dh), child: content),
          ),
        ),
      );
    }

    if (showGeometry) {
      if (clip.quarterTurns % 4 != 0) {
        content = RotatedBox(quarterTurns: clip.quarterTurns % 4, child: content);
      }
      if (clip.flipHorizontal || clip.flipVertical) {
        content = Transform(
          alignment: Alignment.center,
          transform: Matrix4.diagonal3Values(
            clip.flipHorizontal ? -1 : 1,
            clip.flipVertical ? -1 : 1,
            1,
          ),
          child: content,
        );
      }
    }

    final matrix = ColorMatrix.forClip(clip);
    if (!ColorMatrix.isIdentity(matrix)) {
      content = ColorFiltered(colorFilter: ColorFilter.matrix(matrix), child: content);
    }

    return ClipRect(
      child: SizedBox.expand(
        child: FittedBox(
          fit: fit == CanvasFit.fill && showCrop ? BoxFit.cover : BoxFit.contain,
          child: content,
        ),
      ),
    );
  }
}
