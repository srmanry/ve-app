import 'package:flutter_test/flutter_test.dart';
import 'package:video_editor_app/domain/entities/canvas_settings.dart';
import 'package:video_editor_app/domain/entities/export_settings.dart';
import 'package:video_editor_app/domain/entities/project_timeline.dart';
import 'package:video_editor_app/domain/entities/transition.dart';
import 'package:video_editor_app/domain/entities/video_clip.dart';

import '../helpers/fixtures.dart';

void main() {
  group('ProjectTimeline', () {
    test('clips play back-to-back without transitions', () {
      final t = ProjectTimeline(project([clip('a', seconds: 5), clip('b', seconds: 3)]));
      expect(t.clipStart(0), Duration.zero);
      expect(t.clipStart(1), const Duration(seconds: 5));
      expect(t.duration, const Duration(seconds: 8));
    });

    test('speed changes clip length on the timeline', () {
      final t = ProjectTimeline(project([clip('a', seconds: 10, speed: 2), clip('b', seconds: 3, speed: 0.5)]));
      expect(t.duration, const Duration(seconds: 11));
    });

    test('transitions overlap clips and shorten the total', () {
      final t = ProjectTimeline(project([
        clip('a', seconds: 5, transition: TransitionType.fade),
        clip('b', seconds: 5),
      ]));
      expect(t.transitionAfter(0), const Duration(seconds: 1));
      expect(t.clipStart(1), const Duration(seconds: 4));
      expect(t.duration, const Duration(seconds: 9));
    });

    test('transition is clamped to half the shorter neighbour', () {
      final t = ProjectTimeline(project([
        clip('a', seconds: 10, transition: TransitionType.slide, transitionDuration: const Duration(seconds: 2)),
        clip('b', seconds: 2),
      ]));
      expect(t.transitionAfter(0), const Duration(seconds: 1));
    });

    test('last clip transition is ignored', () {
      final t = ProjectTimeline(project([clip('a', seconds: 4, transition: TransitionType.fade)]));
      expect(t.transitionAfter(0), Duration.zero);
      expect(t.duration, const Duration(seconds: 4));
    });

    test('locate maps timeline time to clip and source position', () {
      final c = clip('b', seconds: 10, speed: 2).copyWith(trimStart: const Duration(seconds: 2));
      final t = ProjectTimeline(project([clip('a', seconds: 5), c]));
      final pos = t.locate(const Duration(seconds: 6))!;
      expect(pos.index, 1);
      expect(pos.local, const Duration(seconds: 1));
      // 1s of timeline at 2x = 2s of source, after a 2s trim.
      expect(pos.sourcePosition, const Duration(seconds: 4));
    });

    test('locate switches clips at the middle of a transition', () {
      final t = ProjectTimeline(project([
        clip('a', seconds: 5, transition: TransitionType.fade, transitionDuration: const Duration(seconds: 2)),
        clip('b', seconds: 5),
      ]));
      // Overlap is 3s..5s, switch point at 4s.
      expect(t.locate(const Duration(milliseconds: 3900))!.index, 0);
      expect(t.locate(const Duration(milliseconds: 4100))!.index, 1);
      final tr = t.transitionAt(const Duration(seconds: 4))!;
      expect(tr.fromIndex, 0);
      expect(tr.progress, closeTo(0.5, 1e-9));
    });

    test('output size follows canvas aspect and resolution, always even', () {
      final p = project([clip('a')]);
      expect(ProjectTimeline(p).outputSize(const ExportSettings(resolution: ExportResolution.p720)),
          (width: 1280, height: 720));

      final portrait = p.copyWith(canvas: const CanvasSettings(aspectRatio: AspectRatioPreset.portrait9x16));
      expect(ProjectTimeline(portrait).outputSize(const ExportSettings(resolution: ExportResolution.p1080)),
          (width: 1080, height: 1920));

      final square = p.copyWith(canvas: const CanvasSettings(aspectRatio: AspectRatioPreset.square1x1));
      expect(ProjectTimeline(square).outputSize(const ExportSettings(resolution: ExportResolution.p480)),
          (width: 480, height: 480));

      final fourFive = p.copyWith(canvas: const CanvasSettings(aspectRatio: AspectRatioPreset.portrait4x5));
      expect(ProjectTimeline(fourFive).outputSize(const ExportSettings(resolution: ExportResolution.p1080)),
          (width: 1080, height: 1350));
    });

    test('original canvas uses the rotated, cropped first clip', () {
      final rotated = clip('a', media: videoInfo(width: 1920, height: 1080, rotation: 90));
      final size = ProjectTimeline(project([rotated]))
          .outputSize(const ExportSettings(resolution: ExportResolution.original));
      expect(size, (width: 1080, height: 1920));

      final cropped = clip('b').copyWith(crop: const CropRect(0, 0, 0.5, 1), quarterTurns: 1);
      // Crop 960x1080, then rotate -> 1080 wide x 960 tall.
      final s2 = ProjectTimeline(project([cropped]))
          .outputSize(const ExportSettings(resolution: ExportResolution.original));
      expect(s2.width, greaterThan(s2.height));
    });

    test('size estimate scales with duration and bitrate', () {
      final t = ProjectTimeline(project([clip('a', seconds: 60)]));
      const s = ExportSettings(resolution: ExportResolution.p720, quality: ExportQuality.custom, customBitrateKbps: 2000);
      // (2000 + 128) kbps * 60 s / 8 ≈ 16 MB (+3% overhead).
      expect(t.estimateOutputBytes(s), closeTo(16.44e6, 0.2e6));
    });
  });

  group('Export targets', () {
    test('platform presets set shape, resolution and quality', () {
      final s = const ExportSettings().withTarget(ExportTarget.tiktok);
      expect(s.aspectRatio, AspectRatioPreset.portrait9x16);
      expect(s.resolution, ExportResolution.p1080);
      final whatsapp = s.withTarget(ExportTarget.whatsappStatus);
      expect(whatsapp.resolution, ExportResolution.p720);
      expect(whatsapp.quality, ExportQuality.medium);
    });

    test('export shape overrides the canvas without touching the project', () {
      final p = project([clip('a')]); // 16:9 source, original canvas
      final s = const ExportSettings()
          .withTarget(ExportTarget.instagramReels)
          .copyWith(fit: CanvasFit.fill);
      final exported = p.copyWith(canvas: s.canvasFor(p.canvas));
      expect(ProjectTimeline(exported).outputSize(s), (width: 1080, height: 1920));
      expect(exported.canvas.fit, CanvasFit.fill);
      expect(p.canvas.aspectRatio, AspectRatioPreset.original);
    });

    test('Original keeps the project framing and drops fit overrides', () {
      final s = const ExportSettings()
          .withTarget(ExportTarget.youtube)
          .copyWith(fit: CanvasFit.fill)
          .withTarget(ExportTarget.original);
      expect(s.aspectRatio, isNull);
      expect(s.fit, isNull);
    });

    test('custom keeps whatever was chosen', () {
      final s = const ExportSettings(aspectRatio: AspectRatioPreset.square1x1, frameRate: 60)
          .withTarget(ExportTarget.custom);
      expect(s.aspectRatio, AspectRatioPreset.square1x1);
      expect(s.frameRate, 60);
    });
  });
}
