import 'package:video_editor_app/domain/entities/media_info.dart';
import 'package:video_editor_app/domain/entities/project.dart';
import 'package:video_editor_app/domain/entities/transition.dart';
import 'package:video_editor_app/domain/entities/video_clip.dart';

MediaInfo videoInfo({
  int seconds = 10,
  int width = 1920,
  int height = 1080,
  int rotation = 0,
  bool audio = true,
}) =>
    MediaInfo(
      duration: Duration(seconds: seconds),
      hasVideo: true,
      hasAudio: audio,
      width: width,
      height: height,
      rotation: rotation,
      frameRate: 30,
      videoCodec: 'h264',
      fileSize: 1000000,
    );

VideoClip clip(
  String id, {
  int seconds = 10,
  double speed = 1,
  TransitionType transition = TransitionType.none,
  Duration transitionDuration = const Duration(seconds: 1),
  MediaInfo? media,
}) =>
    VideoClip(
      id: id,
      sourcePath: 'media/$id.mp4',
      media: media ?? videoInfo(seconds: seconds),
      trimStart: Duration.zero,
      trimEnd: Duration(seconds: seconds),
      speed: speed,
      transition: ClipTransition(type: transition, duration: transitionDuration),
    );

Project project(List<VideoClip> clips) => Project(
      id: 'p1',
      name: 'Test',
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 1),
      clips: clips,
    );
