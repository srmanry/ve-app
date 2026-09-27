/// Technical metadata of an imported media file (video, audio or photo).
class MediaInfo {
  const MediaInfo({
    required this.duration,
    required this.hasVideo,
    required this.hasAudio,
    this.width = 0,
    this.height = 0,
    this.rotation = 0,
    this.frameRate,
    this.videoCodec,
    this.audioCodec,
    this.bitrate,
    this.fileSize = 0,
    this.formatName,
    this.isStillImage = false,
  });

  /// Longest a photo can be shown on the timeline. A photo has no natural
  /// length, so it is modelled as a source this long that clips trim into.
  static const stillImageMaxDuration = Duration(minutes: 10);

  factory MediaInfo.stillImage({required int width, required int height, int fileSize = 0}) =>
      MediaInfo(
        duration: stillImageMaxDuration,
        hasVideo: true,
        hasAudio: false,
        width: width,
        height: height,
        videoCodec: 'mjpeg',
        fileSize: fileSize,
        isStillImage: true,
      );

  final Duration duration;

  /// Coded (storage) dimensions, before applying [rotation].
  final int width;
  final int height;

  /// Display rotation in degrees (0, 90, 180, 270) from container metadata.
  final int rotation;
  final double? frameRate;
  final bool hasVideo;
  final bool hasAudio;
  final String? videoCodec;
  final String? audioCodec;
  final int? bitrate;
  final int fileSize;
  final String? formatName;

  /// A photo, rendered as a still frame for as long as its clip lasts.
  final bool isStillImage;

  bool get _swapsAxes => rotation % 180 != 0;

  /// Dimensions as the video is displayed (FFmpeg auto-rotates on decode,
  /// and players apply the rotation too).
  int get displayWidth => _swapsAxes ? height : width;
  int get displayHeight => _swapsAxes ? width : height;

  double get aspectRatio => displayHeight == 0 ? 16 / 9 : displayWidth / displayHeight;

  bool get isPortrait => displayHeight > displayWidth;

  MediaInfo copyWith({Duration? duration, int? fileSize, String? videoCodec}) => MediaInfo(
    duration: duration ?? this.duration,
    hasVideo: hasVideo,
    hasAudio: hasAudio,
    width: width,
    height: height,
    rotation: rotation,
    frameRate: frameRate,
    videoCodec: videoCodec ?? this.videoCodec,
    audioCodec: audioCodec,
    bitrate: bitrate,
    fileSize: fileSize ?? this.fileSize,
    formatName: formatName,
    isStillImage: isStillImage,
  );
}
