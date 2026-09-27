// On-device end-to-end test: real FFmpegKit, real file system, real UI.
//
//   flutter test integration_test/app_e2e_test.dart -d <device-id>
//
// Source media is generated on the device with FFmpeg's lavfi test sources,
// so no fixtures or network are needed.
import 'dart:io';

import 'package:ffmpeg_kit_flutter_new_min_gpl/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_min_gpl/return_code.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_editor_app/app/app.dart';
import 'package:video_editor_app/app/providers.dart';
import 'package:video_editor_app/core/errors/app_exception.dart';
import 'package:video_editor_app/core/storage/app_paths.dart';
import 'package:video_editor_app/domain/entities/color_adjustments.dart';
import 'package:video_editor_app/domain/entities/export_settings.dart';
import 'package:video_editor_app/domain/entities/project_timeline.dart';
import 'package:video_editor_app/domain/entities/sticker_layer.dart';
import 'package:video_editor_app/domain/entities/transition.dart';
import 'package:video_editor_app/domain/entities/video_clip.dart';
import 'package:video_editor_app/services/video/video_processing_service.dart';
import 'package:video_editor_app/domain/repositories/media_repository.dart';
import 'package:video_editor_app/domain/usecases/project_usecases.dart';
import 'package:video_editor_app/presentation/editor/state/editor_controller.dart';

Future<void> _ffmpeg(List<String> args) async {
  final session = await FFmpegKit.executeWithArguments(['-hide_banner', '-y', ...args]);
  final rc = await session.getReturnCode();
  if (!ReturnCode.isSuccess(rc)) {
    fail('ffmpeg failed: ${args.join(' ')}\n${await session.getAllLogsAsString()}');
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('import → edit → export → UI', (tester) async {
    SharedPreferences.setMockInitialValues({'settings.onboardingCompleted': true});
    final prefs = await SharedPreferences.getInstance();
    final paths = await AppPaths.resolve();
    final container = ProviderContainer(overrides: [
      appPathsProvider.overrideWithValue(paths),
      sharedPreferencesProvider.overrideWithValue(prefs),
    ]);
    addTearDown(container.dispose);

    // 1. Generate sources on the device.
    final src = await paths.createJobDir('e2e_src');
    final a = p.join(src.path, 'landscape clip.mp4');
    final b = p.join(src.path, 'portrait.mov');
    final c = p.join(src.path, 'no audio.mkv');
    final music = p.join(src.path, 'music.m4a');
    await _ffmpeg(['-f', 'lavfi', '-i', 'testsrc2=size=1280x720:rate=30', '-f', 'lavfi',
      '-i', 'sine=frequency=440', '-t', '4', '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-c:a', 'aac', a]);
    await _ffmpeg(['-f', 'lavfi', '-i', 'testsrc=size=720x1280:rate=25', '-f', 'lavfi',
      '-i', 'sine=frequency=660', '-t', '3', '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-c:a', 'aac', b]);
    await _ffmpeg(['-f', 'lavfi', '-i', 'mandelbrot=size=640x480:rate=24', '-t', '3',
      '-c:v', 'libx264', '-pix_fmt', 'yuv420p', c]);
    await _ffmpeg(['-f', 'lavfi', '-i', 'sine=frequency=220', '-t', '8', '-c:a', 'aac', music]);
    final photo = p.join(src.path, 'holiday photo.jpg');
    await _ffmpeg(['-f', 'lavfi', '-i', 'smptebars=size=3000x4000', '-frames:v', '1', photo]);

    // 2. Import through the real repository (copy + probe + compatibility).
    final media = container.read(mediaRepositoryProvider);
    final ia = await media.import(PickedMedia(name: 'landscape clip.mp4', path: a), MediaKind.video);
    final ib = await media.import(PickedMedia(name: 'portrait.mov', path: b), MediaKind.video);
    final statuses = <String>[];
    final ic = await media.import(PickedMedia(name: 'no audio.mkv', path: c), MediaKind.video,
        onStatus: statuses.add);
    final im = await media.import(PickedMedia(name: 'music.m4a', path: music), MediaKind.audio);
    final iphoto = await media.import(
      PickedMedia(name: 'holiday photo.jpg', path: photo),
      MediaKind.image,
    );
    // Decoded by the platform, downsized to ≤ 2160 px, stored as JPEG.
    expect(iphoto.info.isStillImage, isTrue);
    expect(iphoto.relativePath, endsWith('.jpg'));
    expect((iphoto.info.width, iphoto.info.height), (1620, 2160));

    expect(ia.info.displayWidth, 1280);
    expect(ib.info.isPortrait, isTrue);
    expect(ic.info.hasAudio, isFalse);
    if (Platform.isIOS) {
      // AVPlayer can't play MKV: it must have been converted for preview.
      expect(ic.relativePath, endsWith('_edit.mp4'));
      expect(statuses.any((s) => s.startsWith('Converting')), isTrue);
    }

    // Unsupported file is rejected with a friendly error.
    final junk = File(p.join(src.path, 'junk.mp4'))..writeAsStringSync('not a video');
    await expectLater(
      media.import(PickedMedia(name: 'junk.mp4', path: junk.path), MediaKind.video),
      throwsA(isA<Exception>()),
    );

    // 3. Build a project using the editor controller, like the UI does.
    final project = await CreateProject(container.read(projectRepositoryProvider))(
      [ia, ib, ic],
      name: 'E2E project',
    );
    final editor = ProviderContainer(parent: container, overrides: [
      editorProvider.overrideWith(() => EditorController(project)),
    ]);
    addTearDown(editor.dispose);
    editor.listen(editorProvider, (_, _) {});
    final ctl = editor.read(editorProvider.notifier);
    final clips = ctl.project.clips;
    ctl.addClips([iphoto]); // appended after the last clip
    expect(ctl.project.clips.last.isStill, isTrue);
    ctl.setTransition(0, const ClipTransition(type: TransitionType.crossDissolve));
    ctl.setTransition(1, const ClipTransition(type: TransitionType.slide));
    ctl.setFilter(clips[0].id, FilterPreset.warm);
    ctl.setAdjustments(clips[1].id, const ColorAdjustments(contrast: 0.3, saturation: 0.4));
    ctl.setSpeed(clips[2].id, 2.0);
    expect(ctl.splitAt(const Duration(seconds: 2)), isNull);
    ctl.addText('Hello offline', const Duration(milliseconds: 500));
    final textId = ctl.project.textLayers.single.id;
    ctl.updateText(textId, (t) => t.copyWith(
          style: t.style.copyWith(fontFamily: 'Pacifico', backgroundColor: 0x99000000, strokeWidth: 0.06),
        ));
    ctl.addSticker(const StickerSpec.emoji('🔥'), const Duration(seconds: 1));
    ctl.addSticker(const StickerSpec.shape(StickerShape.star), const Duration(seconds: 3));
    ctl.addAudio(im, Duration.zero);
    ctl.addPip(ib, const Duration(seconds: 1));
    await ctl.save();
    final edited = ctl.project;
    expect(edited.coverPath, isNotNull);
    expect(File(paths.toAbsolute(edited.coverPath!)).existsSync(), isTrue);

    // 4. Export through the real service (overlays rasterised by Flutter).
    final settings = const ExportSettings(resolution: ExportResolution.p480, frameRate: 30);
    final job = container.read(exportServiceProvider).exportProject(edited, settings);
    final stages = <String>{};
    job.progress.listen((p) => stages.add(p.stage.name));
    final exported = await job.result.timeout(const Duration(minutes: 5));
    final out = File(container.read(exportRepositoryProvider).resolvePath(exported));
    expect(out.existsSync(), isTrue);
    final expected = ProjectTimeline(edited).duration;
    expect(exported.duration.inMilliseconds, closeTo(expected.inMilliseconds, 200));
    expect((exported.width, exported.height), (854, 480));
    expect(stages, containsAll(['preparing', 'renderingOverlays', 'encoding', 'finalizing']));
    // Temp job directories are cleaned up.
    final leftovers = paths.temp.listSync().where((e) => p.basename(e.path).startsWith('export_'));
    expect(leftovers, isEmpty);
    debugPrint('E2E export: ${out.path} ${exported.sizeBytes} bytes, ${exported.duration}');
    // Simulator only: keep a copy on the host for visual inspection.
    const copyDir = String.fromEnvironment('E2E_COPY_DIR');
    if (copyDir.isNotEmpty) out.copySync(p.join(copyDir, 'e2e_export.mp4'));

    // 5. Cancellation leaves nothing behind.
    final slow = edited.copyWith(clips: [for (final c in edited.clips) c.copyWith(speed: 0.25)]);
    final cancelJob = container.read(exportServiceProvider)
        .exportProject(slow, const ExportSettings(resolution: ExportResolution.p1080));
    var cancelled = false;
    cancelJob.progress.listen((p) {
      if (p.stage.name == 'encoding' && !cancelled) {
        cancelled = true;
        cancelJob.cancel();
      }
    });
    await expectLater(
      cancelJob.result,
      throwsA(isA<AppException>().having((e) => e.isCancellation, 'isCancellation', isTrue)),
    );
    expect(paths.temp.listSync().where((e) => p.basename(e.path).startsWith('export_')), isEmpty);

    // 6. Drive the real UI: Home → project → editor.
    await tester.pumpWidget(
        UncontrolledProviderScope(container: container, child: const VideoEditorApp()));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }
    expect(find.text('Create New Video'), findsOneWidget);
    debugPrint('SCREEN:home');
    await Future<void>.delayed(const Duration(seconds: 4));
    await tester.pump();

    await tester.scrollUntilVisible(find.text('E2E project').first, 250,
        scrollable: find.byType(Scrollable).first);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('E2E project').first);
    for (var i = 0; i < 24; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }
    expect(find.text('Export'), findsOneWidget);
    debugPrint('SCREEN:editor');
    for (var i = 0; i < 24; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }

    // Select the text layer on the timeline, then open the Text tool
    // (scrolling the tool bar to reveal it).
    await tester.tap(find.text('Hello offline').last);
    await tester.pump(const Duration(milliseconds: 300));
    final toolText = find.descendant(of: find.byType(ListView).last, matching: find.text('Text'));
    await tester.dragUntilVisible(toolText, find.byType(ListView).last, const Offset(-150, 0));
    await tester.tap(toolText);
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }
    expect(find.text('Bold'), findsNothing);
    expect(find.text('Background'), findsOneWidget);
    debugPrint('SCREEN:text-panel');
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }

    // Export options screen.
    await tester.tap(find.text('Export'));
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }
    // Pick a platform preset: the output switches to 9:16 at 1080p.
    expect(find.text('Original (full)'), findsOneWidget);
    await tester.tap(find.text('TikTok'));
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }
    debugPrint('SCREEN:export-platforms');
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }
    await tester.scrollUntilVisible(
      find.text('Export video'),
      300,
      scrollable: find
          .descendant(of: find.byKey(const ValueKey('options')), matching: find.byType(Scrollable))
          .first,
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('1080×1920 · 30 fps'), findsOneWidget);
    expect(find.textContaining('Estimated size'), findsOneWidget);
    debugPrint('SCREEN:export');
    for (var i = 0; i < 16; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }
  }, timeout: const Timeout(Duration(minutes: 10)));

  // Needs a real photo of a person (host path, simulator only):
  //   --dart-define=PERSON_PHOTO=/path/to/person.jpg
  const personPhoto = String.fromEnvironment('PERSON_PHOTO');
  testWidgets('AI background removal (photo and video)', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final paths = await AppPaths.resolve();
    final container = ProviderContainer(overrides: [
      appPathsProvider.overrideWithValue(paths),
      sharedPreferencesProvider.overrideWithValue(prefs),
    ]);
    addTearDown(container.dispose);
    final media = container.read(mediaRepositoryProvider);
    final service = container.read(backgroundRemovalProvider);
    const copyDir = String.fromEnvironment('E2E_COPY_DIR');

    // Photo.
    final photo = await media.import(const PickedMedia(name: 'person.jpg', path: personPhoto), MediaKind.image);
    final photoClip = VideoClip.fromMedia(id: 'p', sourcePath: photo.relativePath, media: photo.info);
    final stages = <String>[];
    final photoJob = service.start(photoClip, const BackgroundFill.color(0xFF2962FF));
    photoJob.progress.listen((p) => stages.add(p.label));
    final ImportedMedia photoResult;
    try {
      photoResult = await photoJob.result.timeout(const Duration(minutes: 2));
    } on AppException catch (e) {
      // The iOS Simulator has no Vision ML runtime: the app must say so
      // clearly (the pipeline itself is covered on device and on desktop).
      if (e.debugDetails?.contains('UNSUPPORTED_DEVICE') ?? false) {
        expect(e.message, contains('real phone'));
        expect(paths.temp.listSync().where((d) => p.basename(d.path).startsWith('bgremove_')), isEmpty);
        debugPrint('AI: segmentation unavailable here (simulator) — friendly error verified');
        return;
      }
      rethrow;
    }
    expect(photoResult.info.isStillImage, isTrue);
    expect(stages.any((s) => s.startsWith('Finding people')), isTrue);
    if (copyDir.isNotEmpty) {
      File(media.resolve(photoResult.relativePath)).copySync(p.join(copyDir, 'bg_photo.jpg'));
    }

    // Video made from the photo with a slow zoom (so frames differ).
    final src = await paths.createJobDir('bg_src');
    final videoPath = p.join(src.path, 'person.mp4');
    await _ffmpeg(['-loop', '1', '-framerate', '30', '-t', '3', '-i', media.resolve(photo.relativePath),
      '-f', 'lavfi', '-i', 'sine=frequency=330', '-t', '3',
      '-vf', "scale=720:-2,zoompan=z='1+0.002*on':d=1:s=720x1080:fps=30",
      '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-c:a', 'aac', '-shortest', videoPath]);
    final video = await media.import(PickedMedia(name: 'person.mp4', path: videoPath), MediaKind.video);
    final videoClip = VideoClip.fromMedia(id: 'v', sourcePath: video.relativePath, media: video.info);
    final videoResult = await service
        .start(videoClip, const BackgroundFill.blur())
        .result
        .timeout(const Duration(minutes: 5));
    expect(videoResult.info.hasAudio, isTrue);
    expect(videoResult.info.duration.inMilliseconds, closeTo(3000, 200));
    if (copyDir.isNotEmpty) {
      File(media.resolve(videoResult.relativePath)).copySync(p.join(copyDir, 'bg_video.mp4'));
    }
    // Scratch files are cleaned up.
    expect(paths.temp.listSync().where((e) => p.basename(e.path).startsWith('bgremove_')), isEmpty);

    // Cancelling stops the job with a cancellation error.
    final cancelJob = service.start(videoClip, const BackgroundFill.color(0xFF000000));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await cancelJob.cancel();
    await expectLater(
      cancelJob.result,
      throwsA(isA<AppException>().having((e) => e.isCancellation, 'isCancellation', isTrue)),
    );
  }, skip: personPhoto.isEmpty, timeout: const Timeout(Duration(minutes: 10)));
}
