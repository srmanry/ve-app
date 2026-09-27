import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_editor_app/data/models/project_json.dart';
import 'package:video_editor_app/domain/entities/logo_placement.dart';
import 'package:video_editor_app/domain/entities/sticker_layer.dart';
import 'package:video_editor_app/presentation/editor/state/editor_controller.dart';
import 'package:video_editor_app/presentation/editor/state/editor_state.dart';
import 'package:video_editor_app/services/overlay/overlay_painter.dart';

import '../helpers/fixtures.dart';

void main() {
  group('LogoPlacement', () {
    test('corner logos stay fully inside the frame on any canvas shape', () {
      for (final aspect in [16 / 9, 9 / 16, 1.0, 4 / 5]) {
        for (final pos in LogoPosition.values) {
          final t = LogoPlacement.transformFor(pos, 1.0, aspect);
          final halfH = 0.1 * (aspect < 1 ? aspect : 1.0) * t.scale;
          final halfW = halfH / aspect;
          expect(t.x - halfW, greaterThanOrEqualTo(0), reason: '$pos @ $aspect');
          expect(t.x + halfW, lessThanOrEqualTo(1), reason: '$pos @ $aspect');
          expect(t.y - halfH, greaterThanOrEqualTo(0), reason: '$pos @ $aspect');
          expect(t.y + halfH, lessThanOrEqualTo(1), reason: '$pos @ $aspect');
        }
      }
      final tr = LogoPlacement.transformFor(LogoPosition.topRight, 1, 16 / 9);
      expect(tr.x, greaterThan(0.8));
      expect(tr.y, lessThan(0.2));
    });

    test('logo stickers survive a project save/load', () {
      final p = project([clip('a')]).copyWith(stickerLayers: [
        LogoPlacement.layer(
          id: 'logo',
          logoPath: 'logos/brand.png',
          duration: const Duration(seconds: 10),
          canvasAspect: 16 / 9,
        ),
      ]);
      final decoded = ProjectJson.decode(ProjectJson.encode(p));
      final logo = decoded.stickerLayers.single;
      expect(logo.sticker.isImage, isTrue);
      expect(logo.sticker.value, 'logos/brand.png');
      expect(logo.opacity, LogoPlacement.defaultOpacity);
    });
  });

  group('Editor logo actions', () {
    late ProviderContainer container;
    late EditorController controller;

    setUp(() {
      container = ProviderContainer(overrides: [
        editorProvider.overrideWith(() => EditorController(project([clip('a'), clip('b', seconds: 5)]))),
      ]);
      container.listen(editorProvider, (_, _) {});
      controller = container.read(editorProvider.notifier);
    });
    tearDown(() => container.dispose());

    test('addLogo covers the whole video; placeLogo keeps the size', () {
      controller.addLogo('logos/x.png');
      final state = container.read(editorProvider);
      final logo = state.project.stickerLayers.single;
      expect(logo.start, Duration.zero);
      expect(logo.duration, const Duration(seconds: 15));
      expect(state.selection, EditorSelection(SelectionKind.sticker, logo.id));

      controller.updateSticker(logo.id, (s) => s.copyWith(transform: s.transform.copyWith(scale: 1.5)));
      controller.placeLogo(logo.id, LogoPosition.bottomLeft);
      final moved = container.read(editorProvider).project.stickerLayers.single;
      expect(moved.transform.scale, 1.5);
      expect(moved.transform.x, lessThan(0.3));
      expect(moved.transform.y, greaterThan(0.7));
    });

    test('camera logo covers only the recorded takes', () {
      controller.select(const EditorSelection(SelectionKind.clip, 'b'));
      controller.addClips(
        const [],
        recorded: [clip('take', seconds: 4)],
        logo: const CameraLogo(path: 'logos/x.png'),
      );
      final logo = container.read(editorProvider).project.stickerLayers.single;
      expect(logo.start, const Duration(seconds: 15)); // after a (10 s) + b (5 s)
      expect(logo.duration, const Duration(seconds: 4));
    });
  });

  testWidgets('export rasterises logos with their transparency', (tester) async {
    await tester.runAsync(() async {
      // A 100×50 logo: opaque red rectangle on a transparent background.
      final dir = await Directory.systemTemp.createTemp('logo_test');
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawRect(
        const Rect.fromLTWH(25, 10, 50, 30),
        Paint()..color = const Color(0xFFFF0000),
      );
      final logoImage = await recorder.endRecording().toImage(100, 50);
      final png = await logoImage.toByteData(format: ui.ImageByteFormat.png);
      final logoFile = File('${dir.path}/logo.png')..writeAsBytesSync(png!.buffer.asUint8List());

      const canvas = Size(400, 400);
      final layer = const StickerLayer(
        id: 'l',
        sticker: StickerSpec.image('logo.png'),
        start: Duration.zero,
        duration: Duration(seconds: 1),
      ); // centred, scale 1 → 80×80 box, logo fitted as 80×40
      final bytes = await OverlayPainter.rasterize(
        layer,
        canvas,
        resolveImage: (_) => logoFile.path,
      );
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = (await codec.getNextFrame()).image;
      final data = (await frame.toByteData(format: ui.ImageByteFormat.rawRgba))!;
      int alphaAt(int x, int y) => data.getUint8((y * 400 + x) * 4 + 3);
      int redAt(int x, int y) => data.getUint8((y * 400 + x) * 4);

      expect(alphaAt(200, 200), greaterThan(200)); // centre of the red rectangle
      expect(redAt(200, 200), greaterThan(200));
      expect(alphaAt(170, 185), 0); // transparent part of the logo stays transparent
      expect(alphaAt(10, 10), 0); // rest of the frame untouched
      await dir.delete(recursive: true);
    });
  });
}
