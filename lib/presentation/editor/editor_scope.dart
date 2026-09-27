import 'package:flutter/widgets.dart';

import 'playback/playback_controller.dart';
import 'preview/crop_overlay.dart';

/// Per-editor-screen objects that are not Riverpod state: the playback
/// engine (a ChangeNotifier owning native players) and transient UI state.
class EditorScope extends InheritedWidget {
  const EditorScope({
    super.key,
    required this.playback,
    required this.cropAspect,
    required super.child,
  });

  final PlaybackController playback;
  final ValueNotifier<CropAspect> cropAspect;

  static EditorScope of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<EditorScope>();
    assert(scope != null, 'No EditorScope above this widget');
    return scope!;
  }

  static PlaybackController playbackOf(BuildContext context) => of(context).playback;

  @override
  bool updateShouldNotify(EditorScope old) =>
      old.playback != playback || old.cropAspect != cropAspect;
}
