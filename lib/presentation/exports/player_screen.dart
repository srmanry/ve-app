import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../core/theme/app_theme.dart';

import '../../core/utils/formatters.dart';

/// Simple full-screen player for exported files (video or audio).
class PlayerScreen extends StatefulWidget {
  const PlayerScreen({super.key, required this.path, required this.title});
  final String path;
  final String title;

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  late final VideoPlayerController _controller;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _controller = VideoPlayerController.file(File(widget.path));
    _controller
        .initialize()
        .then((_) {
          if (!mounted) return;
          setState(() {});
          _controller.play();
        })
        .catchError((Object e) {
          if (mounted) setState(() => _error = e);
        });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return StudioTheme(
      child: Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black,
          title: Text(widget.title, style: const TextStyle(fontSize: 15)),
        ),
        body: SafeArea(
          child: _error != null
              ? const Center(child: Text('This file can\'t be played.'))
              : !_controller.value.isInitialized
              ? const Center(child: CircularProgressIndicator())
              : Column(
                  children: [
                    Expanded(
                      child: Center(
                        child: _controller.value.size.width == 0
                            ? const Icon(Icons.music_note, size: 96, color: Colors.white38)
                            : AspectRatio(
                                aspectRatio: _controller.value.aspectRatio,
                                child: VideoPlayer(_controller),
                              ),
                      ),
                    ),
                    ValueListenableBuilder<VideoPlayerValue>(
                      valueListenable: _controller,
                      builder: (context, v, _) => Padding(
                        padding: const EdgeInsets.fromLTRB(8, 0, 16, 16),
                        child: Row(
                          children: [
                            IconButton(
                              iconSize: 36,
                              onPressed: () =>
                                  v.isPlaying ? _controller.pause() : _controller.play(),
                              icon: Icon(v.isPlaying ? Icons.pause_circle : Icons.play_circle),
                            ),
                            Expanded(
                              child: Slider(
                                value: v.position.inMilliseconds
                                    .clamp(0, v.duration.inMilliseconds)
                                    .toDouble(),
                                max: v.duration.inMilliseconds.toDouble().clamp(1, double.infinity),
                                onChanged: (ms) =>
                                    _controller.seekTo(Duration(milliseconds: ms.round())),
                              ),
                            ),
                            Text(
                              '${Formatters.duration(v.position)} / ${Formatters.duration(v.duration)}',
                              style: const TextStyle(fontSize: 12),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}
