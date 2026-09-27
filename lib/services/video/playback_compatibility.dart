import 'dart:io';

import '../../domain/entities/media_info.dart';

/// Decides whether the platform's native player (used for preview) can play
/// a file directly, or whether it must first be converted to H.264 MP4.
///
/// Platform rules are isolated here so Android and iOS can be tuned
/// independently.
abstract class PlaybackCompatibility {
  const PlaybackCompatibility();

  factory PlaybackCompatibility.forCurrentPlatform() =>
      Platform.isIOS ? const IosPlaybackCompatibility() : const AndroidPlaybackCompatibility();

  bool canPreview(String extension, MediaInfo info);
}

/// AVPlayer: QuickTime/MPEG-4 family containers only; no MKV/WebM/AVI.
class IosPlaybackCompatibility extends PlaybackCompatibility {
  const IosPlaybackCompatibility();

  static const _containers = {'mp4', 'mov', 'm4v', '3gp'};
  static const _codecs = {'h264', 'hevc', 'mpeg4', 'prores'};

  @override
  bool canPreview(String extension, MediaInfo info) =>
      _containers.contains(extension.toLowerCase()) &&
      _codecs.contains(info.videoCodec?.toLowerCase());
}

/// ExoPlayer (Media3): broad container support; codec support is limited
/// to what device decoders reliably handle.
class AndroidPlaybackCompatibility extends PlaybackCompatibility {
  const AndroidPlaybackCompatibility();

  static const _containers = {'mp4', 'mov', 'm4v', '3gp', 'mkv', 'webm'};
  static const _codecs = {'h264', 'hevc', 'vp8', 'vp9', 'mpeg4', 'h263'};

  @override
  bool canPreview(String extension, MediaInfo info) =>
      _containers.contains(extension.toLowerCase()) &&
      _codecs.contains(info.videoCodec?.toLowerCase());
}
