import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_editor_app/core/constants/app_constants.dart';
import 'package:video_editor_app/domain/entities/color_adjustments.dart';
import 'package:video_editor_app/domain/entities/media_info.dart';
import 'package:video_editor_app/domain/entities/video_effect.dart';
import 'package:video_editor_app/domain/entities/project.dart';
import 'package:video_editor_app/domain/repositories/media_repository.dart';
import 'package:video_editor_app/domain/entities/sticker_layer.dart';
import 'package:video_editor_app/domain/entities/transition.dart';
import 'package:video_editor_app/presentation/editor/state/editor_controller.dart';
import 'package:video_editor_app/presentation/editor/state/editor_state.dart';

import '../helpers/fixtures.dart';

void main() {
  late ProviderContainer container;
  late EditorController controller;

  EditorState state() => container.read(editorProvider);
  Project current() => state().project;

  setUp(() {
    container = ProviderContainer(overrides: [
      editorProvider.overrideWith(
          () => EditorController(project([clip('a', seconds: 10), clip('b', seconds: 6)]))),
    ]);
    // Keep the autoDispose provider alive for the test.
    container.listen(editorProvider, (_, _) {});
    controller = container.read(editorProvider.notifier);
  });

  tearDown(() => container.dispose());

  test('split creates two clips covering the original source range', () {
    expect(controller.splitAt(const Duration(seconds: 4)), isNull);
    final clips = current().clips;
    expect(clips, hasLength(3));
    expect(clips[0].trimEnd, const Duration(seconds: 4));
    expect(clips[1].trimStart, const Duration(seconds: 4));
    expect(clips[1].trimEnd, const Duration(seconds: 10));
    expect(clips[0].id, isNot(clips[1].id));
    expect(state().selection, EditorSelection(SelectionKind.clip, clips[1].id));
    expect(state().timeline.duration, const Duration(seconds: 16));
  });

  test('split respects speed when mapping to source time', () {
    controller.setSpeed('a', 2.0); // clip a is now 5 s on the timeline
    controller.splitAt(const Duration(seconds: 2));
    expect(current().clips[0].trimEnd, const Duration(seconds: 4));
  });

  test('split refuses positions at clip edges', () {
    expect(controller.splitAt(const Duration(milliseconds: 50)), isNotNull);
    expect(current().clips, hasLength(2));
  });

  test('undo and redo walk through history', () {
    controller.splitAt(const Duration(seconds: 4));
    controller.deleteClip(current().clips.first.id);
    expect(current().clips, hasLength(2));

    controller.undo();
    expect(current().clips, hasLength(3));
    controller.undo();
    expect(current().clips, hasLength(2));
    expect(state().canUndo, isFalse);

    controller.redo();
    controller.redo();
    expect(current().clips, hasLength(2));
    expect(current().clips.first.trimStart, const Duration(seconds: 4));
    expect(state().canRedo, isFalse);
  });

  test('a new edit clears the redo stack', () {
    controller.setSpeed('a', 2);
    controller.undo();
    expect(state().canRedo, isTrue);
    controller.setSpeed('a', 0.5);
    expect(state().canRedo, isFalse);
  });

  test('continuous gestures produce a single undo step', () {
    controller.beginChange();
    for (var i = 1; i <= 5; i++) {
      controller.trimClip('a', Duration(seconds: i), const Duration(seconds: 10), live: true);
    }
    expect(state().undoStack, hasLength(1));
    controller.undo();
    expect(current().clips.first.trimStart, Duration.zero);
  });

  test('trim is clamped to the source and minimum length', () {
    controller.trimClip('a', const Duration(seconds: -3), const Duration(seconds: 99));
    expect(current().clips.first.trimStart, Duration.zero);
    expect(current().clips.first.trimEnd, const Duration(seconds: 10));

    controller.trimClip('a', const Duration(seconds: 5), const Duration(seconds: 5));
    final c = current().clips.first;
    expect(c.trimEnd - c.trimStart, AppConstants.minClipDuration);
  });

  test('reorder moves clips', () {
    controller.reorderClip(0, 1);
    expect(current().clips.map((c) => c.id), ['b', 'a']);
  });

  test('history is bounded', () {
    for (var i = 0; i < AppConstants.maxUndoSteps + 10; i++) {
      controller.setSpeed('a', i.isEven ? 2 : 1);
    }
    expect(state().undoStack.length, AppConstants.maxUndoSteps);
  });

  test('layers are added at the playhead and clamped to the timeline', () {
    controller.addText('Hello', const Duration(seconds: 14));
    final text = current().textLayers.single;
    expect(text.start, const Duration(seconds: 14));
    expect(text.duration, const Duration(seconds: 2)); // only 2 s left
    expect(state().selection.kind, SelectionKind.text);

    controller.addSticker(const StickerSpec.emoji('🔥'), const Duration(seconds: 1));
    expect(current().stickerLayers.single.duration, const Duration(seconds: 3));
  });

  test('deleteSelection removes the selected layer', () {
    controller.addText('Bye', Duration.zero);
    controller.deleteSelection();
    expect(current().textLayers, isEmpty);
    expect(state().selection, EditorSelection.none);
  });

  test('resizing a text layer keeps a minimum duration', () {
    controller.addText('x', Duration.zero);
    final id = current().textLayers.single.id;
    controller.resizeLayer(EditorSelection(SelectionKind.text, id),
        newEnd: const Duration(milliseconds: 10));
    expect(current().textLayers.single.duration, AppConstants.minClipDuration);
  });

  test('transition can be applied to all clips', () {
    controller.setTransition(0, const ClipTransition(type: TransitionType.fade), applyToAll: true);
    expect(current().clips.every((c) => c.transition.type == TransitionType.fade), isTrue);
    expect(state().timeline.duration, const Duration(seconds: 15));
  });

  test('undo drops a selection that no longer exists', () {
    controller.addText('x', Duration.zero);
    controller.undo();
    expect(state().selection, EditorSelection.none);
  });

  test('photo clips: default duration, no speed, adjustable length', () {
    controller.addClips([
      ImportedMedia(
        relativePath: 'media/p.jpg',
        displayName: 'p.jpg',
        info: MediaInfo.stillImage(width: 800, height: 600),
      ),
    ]);
    final photo = current().clips.firstWhere((c) => c.isStill);
    expect(photo.duration, const Duration(seconds: 3));

    controller.setSpeed(photo.id, 2);
    expect(current().clips.firstWhere((c) => c.isStill).speed, 1.0);

    controller.setStillDuration(photo.id, const Duration(seconds: 7));
    expect(current().clips.firstWhere((c) => c.isStill).duration, const Duration(seconds: 7));
    expect(state().timeline.duration, const Duration(seconds: 23));

    controller.setAllStillDurations(const Duration(seconds: 2));
    expect(state().timeline.duration, const Duration(seconds: 18));
  });

  test('recorded takes keep their camera look when added', () {
    final take = clip('take', seconds: 4).copyWith(
      filter: FilterPreset.warm,
      effect: VideoEffect.vignette,
      speed: 2.0,
    );
    controller.addClips(const [], recorded: [take]);
    final added = current().clips.firstWhere((c) => c.id == 'take');
    expect(added.filter, FilterPreset.warm);
    expect(added.effect, VideoEffect.vignette);
    expect(added.duration, const Duration(seconds: 2));
  });
}
