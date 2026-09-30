import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/formatters.dart';

class PlayerItem {
  const PlayerItem({
    required this.path,
    required this.title,
    required this.audioOnly,
  });

  final String path;
  final String title;
  final bool audioOnly;
}

/// Full-screen player for exported files.
///
/// Video keeps the neutral full-screen preview, while audio gets a dedicated
/// music-player layout instead of an empty black video canvas.
class PlayerScreen extends StatefulWidget {
  const PlayerScreen({
    super.key,
    required this.path,
    required this.title,
    this.audioOnly,
    this.playlist,
    this.initialIndex = 0,
  });

  final String path;
  final String title;

  /// Prefer this when the caller already knows the media type. Temporary
  /// audio previews can omit it and are recognised from their extension.
  final bool? audioOnly;
  final List<PlayerItem>? playlist;
  final int initialIndex;

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  late final List<PlayerItem> _items;
  VideoPlayerController? _controller;
  late int _index;
  int _loadToken = 0;
  bool _loading = true;
  Object? _error;

  PlayerItem get _current => _items[_index];
  bool get _isAudio => _current.audioOnly;
  bool get _hasPrevious => _index > 0;
  bool get _hasNext => _index < _items.length - 1;

  @override
  void initState() {
    super.initState();
    final supplied = widget.playlist;
    _items = supplied == null || supplied.isEmpty
        ? [
            PlayerItem(
              path: widget.path,
              title: widget.title,
              audioOnly: widget.audioOnly ?? _looksLikeAudio(widget.path),
            ),
          ]
        : List.unmodifiable(supplied);
    _index = widget.initialIndex.clamp(0, _items.length - 1);
    unawaited(_load(_index, notify: false));
  }

  Future<void> _load(int index, {bool notify = true}) async {
    if (index < 0 || index >= _items.length) return;
    final token = ++_loadToken;
    final old = _controller;
    _controller = null;
    _index = index;
    _loading = true;
    _error = null;
    if (notify && mounted) setState(() {});

    await old?.dispose();
    if (!mounted || token != _loadToken) return;

    final next = VideoPlayerController.file(File(_current.path));
    _controller = next;
    try {
      await next.initialize();
      if (!mounted || token != _loadToken) return;
      setState(() => _loading = false);
      await next.play();
    } catch (e) {
      if (mounted && token == _loadToken) {
        setState(() {
          _loading = false;
          _error = e;
        });
      }
    }
  }

  @override
  void dispose() {
    _loadToken++;
    unawaited(_controller?.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return StudioTheme(
      child: Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black,
          centerTitle: _isAudio,
          title: Text(
            _current.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 15),
          ),
        ),
        body: SafeArea(
          child: _error != null
              ? const Center(child: Text('This file can\'t be played.'))
              : _loading ||
                    _controller == null ||
                    !_controller!.value.isInitialized
              ? const Center(child: CircularProgressIndicator())
              : _isAudio
              ? _AudioPlayer(
                  controller: _controller!,
                  title: _current.title,
                  onPrevious: _hasPrevious ? () => _load(_index - 1) : null,
                  onNext: _hasNext ? () => _load(_index + 1) : null,
                )
              : _VideoPlayer(
                  controller: _controller!,
                  onPrevious: _hasPrevious ? () => _load(_index - 1) : null,
                  onNext: _hasNext ? () => _load(_index + 1) : null,
                ),
        ),
      ),
    );
  }
}

bool _looksLikeAudio(String path) {
  final cleanPath = Uri.tryParse(path)?.path ?? path;
  final dot = cleanPath.lastIndexOf('.');
  if (dot == -1) return false;
  return const {
    'mp3',
    'm4a',
    'wav',
    'aac',
  }.contains(cleanPath.substring(dot + 1).toLowerCase());
}

class _VideoPlayer extends StatelessWidget {
  const _VideoPlayer({
    required this.controller,
    required this.onPrevious,
    required this.onNext,
  });

  final VideoPlayerController controller;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;

  @override
  Widget build(BuildContext context) =>
      ValueListenableBuilder<VideoPlayerValue>(
        valueListenable: controller,
        builder: (context, value, _) {
          final landscape =
              MediaQuery.orientationOf(context) == Orientation.landscape;
          final stage = _VideoStage(
            controller: controller,
            onPrevious: onPrevious,
            onNext: onNext,
          );
          final controls = _VideoControls(
            controller: controller,
            value: value,
            overlay: landscape,
          );

          if (landscape) {
            return Stack(
              fit: StackFit.expand,
              children: [
                stage,
                Align(alignment: Alignment.bottomCenter, child: controls),
              ],
            );
          }
          return Column(
            children: [
              Expanded(child: stage),
              controls,
            ],
          );
        },
      );
}

class _VideoStage extends StatelessWidget {
  const _VideoStage({
    required this.controller,
    required this.onPrevious,
    required this.onNext,
  });

  final VideoPlayerController controller;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;

  @override
  Widget build(BuildContext context) {
    final size = controller.value.size;
    return Stack(
      fit: StackFit.expand,
      children: [
        Center(
          child: FittedBox(
            fit: BoxFit.contain,
            child: SizedBox(
              width: size.width > 0 ? size.width : 16,
              height: size.height > 0 ? size.height : 9,
              child: VideoPlayer(controller),
            ),
          ),
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: _MediaArrow(
            tooltip: 'Previous file',
            icon: Icons.chevron_left_rounded,
            onPressed: onPrevious,
          ),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: _MediaArrow(
            tooltip: 'Next file',
            icon: Icons.chevron_right_rounded,
            onPressed: onNext,
          ),
        ),
      ],
    );
  }
}

class _VideoControls extends StatelessWidget {
  const _VideoControls({
    required this.controller,
    required this.value,
    required this.overlay,
  });

  final VideoPlayerController controller;
  final VideoPlayerValue value;
  final bool overlay;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: EdgeInsets.fromLTRB(12, overlay ? 20 : 0, 12, overlay ? 8 : 16),
    decoration: overlay
        ? const BoxDecoration(
            gradient: LinearGradient(
              colors: [Colors.transparent, Color(0xE6000000)],
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
            ),
          )
        : null,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _PositionSlider(controller: controller, value: value),
        Row(
          children: [
            SizedBox(
              width: 48,
              child: Text(
                Formatters.duration(value.position),
                style: const TextStyle(fontSize: 11, color: Colors.white60),
              ),
            ),
            const Spacer(),
            IconButton(
              tooltip: 'Back 10 seconds',
              onPressed: () =>
                  _seekRelative(controller, const Duration(seconds: -10)),
              icon: const Icon(Icons.replay_10_rounded),
            ),
            IconButton.filled(
              tooltip: value.isPlaying ? 'Pause' : 'Play',
              style: IconButton.styleFrom(
                backgroundColor: AppColors.accent,
                foregroundColor: Colors.white,
              ),
              onPressed: () =>
                  value.isPlaying ? controller.pause() : controller.play(),
              icon: Icon(
                value.isPlaying
                    ? Icons.pause_rounded
                    : Icons.play_arrow_rounded,
              ),
            ),
            IconButton(
              tooltip: 'Forward 10 seconds',
              onPressed: () =>
                  _seekRelative(controller, const Duration(seconds: 10)),
              icon: const Icon(Icons.forward_10_rounded),
            ),
            const Spacer(),
            SizedBox(
              width: 48,
              child: Text(
                Formatters.duration(value.duration),
                textAlign: TextAlign.right,
                style: const TextStyle(fontSize: 11, color: Colors.white60),
              ),
            ),
          ],
        ),
      ],
    ),
  );
}

class _AudioPlayer extends StatelessWidget {
  const _AudioPlayer({
    required this.controller,
    required this.title,
    required this.onPrevious,
    required this.onNext,
  });

  final VideoPlayerController controller;
  final String title;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;

  @override
  Widget build(BuildContext context) =>
      ValueListenableBuilder<VideoPlayerValue>(
        valueListenable: controller,
        builder: (context, value, _) {
          if (MediaQuery.orientationOf(context) == Orientation.landscape) {
            return Row(
              children: [
                Expanded(
                  child: _AudioArtwork(
                    onPrevious: onPrevious,
                    onNext: onNext,
                    maxSize: 190,
                  ),
                ),
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(12, 8, 24, 12),
                    child: _AudioControls(
                      controller: controller,
                      value: value,
                      title: title,
                      compact: true,
                    ),
                  ),
                ),
              ],
            );
          }
          return Column(
            children: [
              Expanded(
                child: _AudioArtwork(
                  onPrevious: onPrevious,
                  onNext: onNext,
                  maxSize: 260,
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 28),
                child: _AudioControls(
                  controller: controller,
                  value: value,
                  title: title,
                ),
              ),
            ],
          );
        },
      );
}

class _AudioArtwork extends StatelessWidget {
  const _AudioArtwork({
    required this.onPrevious,
    required this.onNext,
    required this.maxSize,
  });

  final VoidCallback? onPrevious;
  final VoidCallback? onNext;
  final double maxSize;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      _MediaArrow(
        tooltip: 'Previous file',
        icon: Icons.chevron_left_rounded,
        onPressed: onPrevious,
      ),
      Expanded(
        child: Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxSize, maxHeight: maxSize),
            child: AspectRatio(
              aspectRatio: 1,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFF282B34), Color(0xFF111217)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(36),
                  border: Border.all(color: Colors.white12),
                  boxShadow: const [
                    BoxShadow(
                      color: Colors.black54,
                      blurRadius: 30,
                      offset: Offset(0, 14),
                    ),
                  ],
                ),
                child: const Center(
                  child: Icon(
                    Icons.music_note_rounded,
                    size: 96,
                    color: Colors.white38,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
      _MediaArrow(
        tooltip: 'Next file',
        icon: Icons.chevron_right_rounded,
        onPressed: onNext,
      ),
    ],
  );
}

class _AudioControls extends StatelessWidget {
  const _AudioControls({
    required this.controller,
    required this.value,
    required this.title,
    this.compact = false,
  });

  final VideoPlayerController controller;
  final VideoPlayerValue value;
  final String title;
  final bool compact;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(
        title,
        maxLines: compact ? 2 : 1,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.center,
        style: TextStyle(
          fontSize: compact ? 15 : 17,
          fontWeight: FontWeight.w600,
        ),
      ),
      const SizedBox(height: 2),
      const Text(
        'Audio track',
        style: TextStyle(fontSize: 12, color: Colors.white54),
      ),
      SizedBox(height: compact ? 6 : 20),
      _PositionSlider(controller: controller, value: value),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              Formatters.duration(value.position),
              style: const TextStyle(fontSize: 11, color: Colors.white60),
            ),
            Text(
              Formatters.duration(value.duration),
              style: const TextStyle(fontSize: 11, color: Colors.white60),
            ),
          ],
        ),
      ),
      SizedBox(height: compact ? 2 : 10),
      Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          IconButton(
            tooltip: 'Back 10 seconds',
            iconSize: 30,
            color: Colors.white70,
            onPressed: () =>
                _seekRelative(controller, const Duration(seconds: -10)),
            icon: const Icon(Icons.replay_10_rounded),
          ),
          SizedBox(width: compact ? 10 : 22),
          IconButton.filled(
            tooltip: value.isPlaying ? 'Pause' : 'Play',
            style: IconButton.styleFrom(
              backgroundColor: AppColors.accent,
              foregroundColor: Colors.white,
              minimumSize: Size.square(compact ? 50 : 64),
            ),
            iconSize: compact ? 30 : 36,
            onPressed: () =>
                value.isPlaying ? controller.pause() : controller.play(),
            icon: Icon(
              value.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
            ),
          ),
          SizedBox(width: compact ? 10 : 22),
          IconButton(
            tooltip: 'Forward 10 seconds',
            iconSize: 30,
            color: Colors.white70,
            onPressed: () =>
                _seekRelative(controller, const Duration(seconds: 10)),
            icon: const Icon(Icons.forward_10_rounded),
          ),
        ],
      ),
    ],
  );
}

class _PositionSlider extends StatelessWidget {
  const _PositionSlider({required this.controller, required this.value});

  final VideoPlayerController controller;
  final VideoPlayerValue value;

  @override
  Widget build(BuildContext context) {
    final durationMs = value.duration.inMilliseconds;
    final positionMs = value.position.inMilliseconds.clamp(0, durationMs);
    return Slider(
      value: positionMs.toDouble(),
      max: durationMs.toDouble().clamp(1, double.infinity),
      onChanged: (ms) => controller.seekTo(Duration(milliseconds: ms.round())),
    );
  }
}

class _MediaArrow extends StatelessWidget {
  const _MediaArrow({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 4),
    child: IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      style: IconButton.styleFrom(
        backgroundColor: Colors.black54,
        disabledBackgroundColor: Colors.black12,
        foregroundColor: Colors.white,
        disabledForegroundColor: Colors.white24,
      ),
      icon: Icon(icon, size: 34),
    ),
  );
}

void _seekRelative(VideoPlayerController controller, Duration offset) {
  final value = controller.value;
  final targetMs = (value.position + offset).inMilliseconds.clamp(
    0,
    value.duration.inMilliseconds,
  );
  controller.seekTo(Duration(milliseconds: targetMs));
}
