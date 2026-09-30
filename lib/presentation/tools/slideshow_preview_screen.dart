import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/formatters.dart';
import '../../domain/entities/project.dart';
import '../editor/editor_scope.dart';
import '../editor/playback/playback_controller.dart';
import '../editor/preview/crop_overlay.dart';
import '../editor/preview/preview_canvas.dart';
import '../editor/state/editor_controller.dart';

/// Read-only slideshow preview. The project only lives in memory and is not
/// saved until the user returns and taps Create video.
class SlideshowPreviewScreen extends StatelessWidget {
  const SlideshowPreviewScreen({super.key, required this.project});

  final Project project;

  @override
  Widget build(BuildContext context) => StudioTheme(
    child: ProviderScope(
      overrides: [editorProvider.overrideWith(() => EditorController(project))],
      child: const _PreviewBody(),
    ),
  );
}

class _PreviewBody extends ConsumerStatefulWidget {
  const _PreviewBody();

  @override
  ConsumerState<_PreviewBody> createState() => _PreviewBodyState();
}

class _PreviewBodyState extends ConsumerState<_PreviewBody> {
  late final PlaybackController _playback;
  final _cropAspect = ValueNotifier(CropAspect.free);

  @override
  void initState() {
    super.initState();
    _playback = PlaybackController(
      project: ref.read(editorProvider).project,
      resolveMedia: ref.read(mediaRepositoryProvider).resolve,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _playback.seek(Duration.zero, fromUser: false);
      unawaited(_playback.play());
    });
  }

  @override
  void dispose() {
    _playback.dispose();
    _cropAspect.dispose();
    super.dispose();
  }

  void _seekRelative(Duration offset) {
    final target = _playback.position.value + offset;
    _playback.seek(target);
  }

  @override
  Widget build(BuildContext context) => EditorScope(
    playback: _playback,
    cropAspect: _cropAspect,
    child: Scaffold(
      backgroundColor: AppColors.darkBackground,
      appBar: AppBar(
        title: const Text('Slideshow preview'),
        backgroundColor: AppColors.darkBackground,
      ),
      body: SafeArea(
        child: Column(
          children: [
            const Expanded(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: PreviewCanvas(),
              ),
            ),
            ValueListenableBuilder<Duration>(
              valueListenable: _playback.position,
              builder: (context, position, _) {
                final durationMs = _playback.duration.inMilliseconds;
                final positionMs = position.inMilliseconds.clamp(0, durationMs);
                return Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
                  child: Column(
                    children: [
                      Slider(
                        value: positionMs.toDouble(),
                        max: durationMs.toDouble().clamp(1, double.infinity),
                        onChanged: (value) => _playback.seek(
                          Duration(milliseconds: value.round()),
                        ),
                      ),
                      Row(
                        children: [
                          SizedBox(
                            width: 54,
                            child: Text(
                              Formatters.duration(position),
                              style: const TextStyle(
                                fontSize: 12,
                                color: Colors.white60,
                              ),
                            ),
                          ),
                          const Spacer(),
                          IconButton(
                            tooltip: 'Back 5 seconds',
                            onPressed: () =>
                                _seekRelative(const Duration(seconds: -5)),
                            icon: const Icon(Icons.replay_5_rounded),
                          ),
                          ListenableBuilder(
                            listenable: _playback,
                            builder: (context, _) => IconButton.filled(
                              tooltip: _playback.isPlaying ? 'Pause' : 'Play',
                              style: IconButton.styleFrom(
                                backgroundColor: AppColors.accent,
                                foregroundColor: Colors.white,
                                minimumSize: const Size.square(56),
                              ),
                              onPressed: _playback.togglePlay,
                              icon: Icon(
                                _playback.isPlaying
                                    ? Icons.pause_rounded
                                    : Icons.play_arrow_rounded,
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: 'Forward 5 seconds',
                            onPressed: () =>
                                _seekRelative(const Duration(seconds: 5)),
                            icon: const Icon(Icons.forward_5_rounded),
                          ),
                          const Spacer(),
                          SizedBox(
                            width: 54,
                            child: Text(
                              Formatters.duration(_playback.duration),
                              textAlign: TextAlign.right,
                              style: const TextStyle(
                                fontSize: 12,
                                color: Colors.white60,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                );
              },
            ),
          ],
        ),
      ),
    ),
  );
}
