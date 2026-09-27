import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_editor_app/data/models/project_json.dart';
import 'package:video_editor_app/domain/entities/audio_track.dart';
import 'package:video_editor_app/domain/entities/canvas_settings.dart';
import 'package:video_editor_app/domain/entities/color_adjustments.dart';
import 'package:video_editor_app/domain/entities/export_settings.dart';
import 'package:video_editor_app/domain/entities/layer_transform.dart';
import 'package:video_editor_app/domain/entities/media_info.dart';
import 'package:video_editor_app/domain/entities/pip_layer.dart';
import 'package:video_editor_app/domain/entities/sticker_layer.dart';
import 'package:video_editor_app/domain/entities/text_layer.dart';
import 'package:video_editor_app/domain/entities/transition.dart';
import 'package:video_editor_app/domain/entities/video_clip.dart';

import '../helpers/fixtures.dart';

void main() {
  test('project survives a JSON round trip', () {
    final original = project([
      clip('a').copyWith(
        speed: 1.5,
        muted: true,
        crop: const CropRect(0.1, 0.2, 0.5, 0.6),
        quarterTurns: 3,
        flipHorizontal: true,
        filter: FilterPreset.vintage,
        filterStrength: 0.4,
        adjustments: const ColorAdjustments(brightness: 0.2, shadows: -0.3),
        transition: const ClipTransition(type: TransitionType.zoom, duration: Duration(milliseconds: 1500)),
      ),
      VideoClip.fromMedia(
        id: 'photo',
        sourcePath: 'media/photo.jpg',
        media: MediaInfo.stillImage(width: 1080, height: 1350, fileSize: 12345),
      ),
    ]).copyWith(
      audioTracks: [
        AudioTrack(
          id: 'm', name: 'Song', sourcePath: 'media/m.m4a', media: videoInfo(),
          start: const Duration(seconds: 2), trimStart: const Duration(seconds: 1),
          trimEnd: const Duration(seconds: 5), volume: 0.7,
        ),
      ],
      textLayers: [
        const TextLayer(
          id: 't', text: 'Hello "world"\nline 2', start: Duration(seconds: 1), duration: Duration(seconds: 3),
          style: TextLayerStyle(fontFamily: 'Pacifico', backgroundColor: 0x80000000, strokeWidth: 0.1,
              align: TextAlignOption.right, italic: true),
          transform: LayerTransform(x: 0.3, y: 0.7, scale: 2, rotation: 0.5),
        ),
      ],
      stickerLayers: [
        const StickerLayer(
          id: 's1', sticker: StickerSpec.shape(StickerShape.heart, color: 0xFFFF0000),
          start: Duration.zero, duration: Duration(seconds: 2),
        ),
        const StickerLayer(
          id: 's2', sticker: StickerSpec.emoji('🎉'), start: Duration.zero, duration: Duration(seconds: 2),
        ),
      ],
      pipLayers: [
        PipLayer(
          id: 'pip', sourcePath: 'media/p.mp4', media: videoInfo(rotation: 90),
          start: const Duration(seconds: 1), trimStart: Duration.zero, trimEnd: const Duration(seconds: 2),
          muted: true,
        ),
      ],
      canvas: const CanvasSettings(aspectRatio: AspectRatioPreset.portrait9x16, fit: CanvasFit.fill),
      exportSettings: const ExportSettings(resolution: ExportResolution.p720, frameRate: 60,
          quality: ExportQuality.custom, customBitrateKbps: 4200, target: ExportTarget.tiktok,
          aspectRatio: AspectRatioPreset.square1x1, fit: CanvasFit.fit),
      coverPath: 'projects/p1.jpg',
    );

    final json = jsonDecode(jsonEncode(ProjectJson.encode(original))) as Map<String, dynamic>;
    final decoded = ProjectJson.decode(json);

    // Re-encoding must be identical: every field survived.
    expect(jsonEncode(ProjectJson.encode(decoded)), jsonEncode(ProjectJson.encode(original)));
    expect(decoded.clips.first.crop, const CropRect(0.1, 0.2, 0.5, 0.6));
    expect(decoded.stickerLayers.first.sticker.value, StickerShape.heart);
    expect(decoded.pipLayers.single.media.isPortrait, isTrue);
    expect(decoded.clips.last.isStill, isTrue);
    expect(decoded.exportSettings.target, ExportTarget.tiktok);
    expect(decoded.exportSettings.aspectRatio, AspectRatioPreset.square1x1);
    expect(decoded.exportSettings.fit, CanvasFit.fit);
    expect(decoded.clips.first.isStill, isFalse);
  });

  test('decoding is lenient with missing and unknown values', () {
    final decoded = ProjectJson.decode({
      'id': 'x',
      'clips': [
        {'id': 'c', 'source': 'media/c.mp4', 'filter': 'doesNotExist', 'media': {'durationUs': 1000000}},
      ],
      'canvas': {'aspectRatio': 'weird'},
      'export': {'frameRate': 17},
    });
    expect(decoded.name, 'Untitled');
    expect(decoded.clips.single.filter, FilterPreset.original);
    expect(decoded.canvas.aspectRatio, AspectRatioPreset.original);
    expect(decoded.exportSettings.frameRate, 30);
  });
}
