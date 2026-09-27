import '../../domain/entities/media_info.dart';

/// Parses ffprobe `-show_format -show_streams` JSON into [MediaInfo].
///
/// Pure function so it can be tested against real ffprobe output.
abstract final class MediaInfoParser {
  static MediaInfo? parse(Map<dynamic, dynamic> json, {int fileSize = 0}) {
    final format = (json['format'] as Map<dynamic, dynamic>?) ?? const {};
    final streams = ((json['streams'] as List<dynamic>?) ?? const [])
        .whereType<Map<dynamic, dynamic>>()
        .toList();

    // Cover art in audio files is reported as a video stream with the
    // attached_pic disposition - it is not real video.
    bool isAttachedPic(Map<dynamic, dynamic> s) {
      final disposition = s['disposition'];
      return disposition is Map && disposition['attached_pic'] == 1;
    }

    final video = streams.where((s) => s['codec_type'] == 'video' && !isAttachedPic(s)).firstOrNull;
    final audio = streams.where((s) => s['codec_type'] == 'audio').firstOrNull;
    if (video == null && audio == null) return null;

    final durationSeconds =
        _double(format['duration']) ?? _double(video?['duration']) ?? _double(audio?['duration']);
    if (durationSeconds == null || durationSeconds <= 0) return null;

    return MediaInfo(
      duration: Duration(microseconds: (durationSeconds * 1e6).round()),
      hasVideo: video != null,
      hasAudio: audio != null,
      width: _int(video?['width']) ?? 0,
      height: _int(video?['height']) ?? 0,
      rotation: video == null ? 0 : _rotation(video),
      frameRate: video == null
          ? null
          : (_rational(video['avg_frame_rate']) ?? _rational(video['r_frame_rate'])),
      videoCodec: video?['codec_name'] as String?,
      audioCodec: audio?['codec_name'] as String?,
      bitrate: _int(format['bit_rate']),
      fileSize: _int(format['size']) ?? fileSize,
      formatName: format['format_name'] as String?,
    );
  }

  /// Rotation comes from the display-matrix side data (modern FFmpeg) or
  /// the legacy `rotate` tag. Normalised to 0/90/180/270.
  static int _rotation(Map<dynamic, dynamic> stream) {
    num? raw;
    final sideData = stream['side_data_list'];
    if (sideData is List) {
      for (final entry in sideData) {
        if (entry is Map && entry['rotation'] != null) {
          raw = _double(entry['rotation']);
          break;
        }
      }
    }
    final tags = stream['tags'];
    if (raw == null && tags is Map) raw = _double(tags['rotate']);
    if (raw == null) return 0;
    final quarter = ((raw / 90).round() * 90) % 360;
    return quarter < 0 ? quarter + 360 : quarter;
  }

  static double? _rational(Object? value) {
    if (value is! String || !value.contains('/')) return _double(value);
    final parts = value.split('/');
    final numerator = double.tryParse(parts[0]);
    final den = double.tryParse(parts[1]);
    if (numerator == null || den == null || den == 0 || numerator == 0) return null;
    return numerator / den;
  }

  static double? _double(Object? value) => switch (value) {
    final num v => v.toDouble(),
    final String v => double.tryParse(v),
    _ => null,
  };

  static int? _int(Object? value) => switch (value) {
    final int v => v,
    final num v => v.toInt(),
    final String v => int.tryParse(v) ?? double.tryParse(v)?.toInt(),
    _ => null,
  };
}
