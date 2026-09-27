import '../../domain/entities/audio_track.dart';
import '../../domain/entities/canvas_settings.dart';
import '../../domain/entities/color_adjustments.dart';
import '../../domain/entities/export_settings.dart';
import '../../domain/entities/layer_transform.dart';
import '../../domain/entities/media_info.dart';
import '../../domain/entities/pip_layer.dart';
import '../../domain/entities/project.dart';
import '../../domain/entities/sticker_layer.dart';
import '../../domain/entities/text_layer.dart';
import '../../domain/entities/transition.dart';
import '../../domain/entities/video_clip.dart';
import '../../domain/entities/video_effect.dart';

/// JSON (de)serialisation for [Project] and everything it contains.
///
/// Kept in the data layer so domain entities stay free of storage concerns.
/// Decoding is lenient: unknown enum values and missing fields fall back to
/// defaults so older/newer project files still open.
abstract final class ProjectJson {
  /// Bump when the format changes incompatibly; add a migration in [decode].
  static const schemaVersion = 1;

  static Map<String, Object?> encode(Project p) => {
    'schema': schemaVersion,
    'id': p.id,
    'name': p.name,
    'createdAt': p.createdAt.toIso8601String(),
    'updatedAt': p.updatedAt.toIso8601String(),
    'coverPath': p.coverPath,
    'clips': p.clips.map(_clip).toList(),
    'audioTracks': p.audioTracks.map(_audio).toList(),
    'textLayers': p.textLayers.map(_text).toList(),
    'stickerLayers': p.stickerLayers.map(_sticker).toList(),
    'pipLayers': p.pipLayers.map(_pip).toList(),
    'canvas': {
      'aspectRatio': p.canvas.aspectRatio.name,
      'fit': p.canvas.fit.name,
      'backgroundColor': p.canvas.backgroundColor,
    },
    'export': encodeExportSettings(p.exportSettings),
  };

  static Project decode(Map<String, Object?> j) {
    final canvas = _map(j['canvas']);
    return Project(
      id: j['id'] as String,
      name: (j['name'] as String?) ?? 'Untitled',
      createdAt: _date(j['createdAt']),
      updatedAt: _date(j['updatedAt']),
      coverPath: j['coverPath'] as String?,
      clips: _maps(j['clips']).map(_decodeClip).toList(),
      audioTracks: _maps(j['audioTracks']).map(_decodeAudio).toList(),
      textLayers: _maps(j['textLayers']).map(_decodeText).toList(),
      stickerLayers: _maps(j['stickerLayers']).map(_decodeSticker).toList(),
      pipLayers: _maps(j['pipLayers']).map(_decodePip).toList(),
      canvas: CanvasSettings(
        aspectRatio: _enum(
          AspectRatioPreset.values,
          canvas['aspectRatio'],
          AspectRatioPreset.original,
        ),
        fit: _enum(CanvasFit.values, canvas['fit'], CanvasFit.fit),
        backgroundColor: _int(canvas['backgroundColor'], 0xFF000000),
      ),
      exportSettings: decodeExportSettings(_map(j['export'])),
    );
  }

  // --- Export settings (also used by app settings) ---------------------------

  static Map<String, Object?> encodeExportSettings(ExportSettings s) => {
    'resolution': s.resolution.name,
    'frameRate': s.frameRate,
    'quality': s.quality.name,
    'customBitrateKbps': s.customBitrateKbps,
    'audioBitrateKbps': s.audioBitrateKbps,
    'format': s.format.name,
    'target': s.target.name,
    'aspectRatio': s.aspectRatio?.name,
    'fit': s.fit?.name,
  };

  static ExportSettings decodeExportSettings(Map<String, Object?> j) {
    final fps = _int(j['frameRate'], 30);
    return ExportSettings(
      resolution: _enum(ExportResolution.values, j['resolution'], ExportResolution.p1080),
      frameRate: ExportSettings.frameRates.contains(fps) ? fps : 30,
      quality: _enum(ExportQuality.values, j['quality'], ExportQuality.high),
      customBitrateKbps: _int(j['customBitrateKbps'], 8000),
      audioBitrateKbps: _int(j['audioBitrateKbps'], 128),
      target: _enum(ExportTarget.values, j['target'], ExportTarget.original),
      aspectRatio: AspectRatioPreset.values.where((e) => e.name == j['aspectRatio']).firstOrNull,
      fit: CanvasFit.values.where((e) => e.name == j['fit']).firstOrNull,
    );
  }

  // --- Media -------------------------------------------------------------------

  static Map<String, Object?> encodeMedia(MediaInfo m) => {
    'durationUs': m.duration.inMicroseconds,
    'width': m.width,
    'height': m.height,
    'rotation': m.rotation,
    'frameRate': m.frameRate,
    'hasVideo': m.hasVideo,
    'hasAudio': m.hasAudio,
    'videoCodec': m.videoCodec,
    'audioCodec': m.audioCodec,
    'bitrate': m.bitrate,
    'fileSize': m.fileSize,
    'formatName': m.formatName,
    if (m.isStillImage) 'still': true,
  };

  static MediaInfo decodeMedia(Map<String, Object?> j) => MediaInfo(
    duration: _dur(j['durationUs']),
    width: _int(j['width'], 0),
    height: _int(j['height'], 0),
    rotation: _int(j['rotation'], 0),
    frameRate: (j['frameRate'] as num?)?.toDouble(),
    hasVideo: (j['hasVideo'] as bool?) ?? true,
    hasAudio: (j['hasAudio'] as bool?) ?? false,
    videoCodec: j['videoCodec'] as String?,
    audioCodec: j['audioCodec'] as String?,
    bitrate: j['bitrate'] as int?,
    fileSize: _int(j['fileSize'], 0),
    formatName: j['formatName'] as String?,
    isStillImage: (j['still'] as bool?) ?? false,
  );

  // --- Clips & layers -----------------------------------------------------------

  static Map<String, Object?> _clip(VideoClip c) => {
    'id': c.id,
    'source': c.sourcePath,
    'media': encodeMedia(c.media),
    'trimStartUs': c.trimStart.inMicroseconds,
    'trimEndUs': c.trimEnd.inMicroseconds,
    'speed': c.speed,
    'volume': c.volume,
    'muted': c.muted,
    'crop': [c.crop.left, c.crop.top, c.crop.width, c.crop.height],
    'quarterTurns': c.quarterTurns,
    'flipH': c.flipHorizontal,
    'flipV': c.flipVertical,
    'filter': c.filter.name,
    'filterStrength': c.filterStrength,
    'adjust': {
      'brightness': c.adjustments.brightness,
      'contrast': c.adjustments.contrast,
      'saturation': c.adjustments.saturation,
      'exposure': c.adjustments.exposure,
      'temperature': c.adjustments.temperature,
      'highlights': c.adjustments.highlights,
      'shadows': c.adjustments.shadows,
    },
    'transition': {
      'type': c.transition.type.name,
      'durationMs': c.transition.duration.inMilliseconds,
    },
    'effect': c.effect.name,
    'effectIntensity': c.effectIntensity,
    'audioDenoise': c.audioDenoise.name,
    'videoDenoise': c.videoDenoise.name,
  };

  static VideoClip _decodeClip(Map<String, Object?> j) {
    final crop = _list<num>(j['crop']);
    final adjust = _map(j['adjust']);
    final transition = _map(j['transition']);
    return VideoClip(
      id: j['id'] as String,
      sourcePath: j['source'] as String,
      media: decodeMedia(_map(j['media'])),
      trimStart: _dur(j['trimStartUs']),
      trimEnd: _dur(j['trimEndUs']),
      speed: _double(j['speed'], 1),
      volume: _double(j['volume'], 1),
      muted: (j['muted'] as bool?) ?? false,
      crop: crop.length == 4
          ? CropRect(crop[0].toDouble(), crop[1].toDouble(), crop[2].toDouble(), crop[3].toDouble())
          : CropRect.full,
      quarterTurns: _int(j['quarterTurns'], 0),
      flipHorizontal: (j['flipH'] as bool?) ?? false,
      flipVertical: (j['flipV'] as bool?) ?? false,
      filter: _enum(FilterPreset.values, j['filter'], FilterPreset.original),
      filterStrength: _double(j['filterStrength'], 1),
      adjustments: ColorAdjustments(
        brightness: _double(adjust['brightness'], 0),
        contrast: _double(adjust['contrast'], 0),
        saturation: _double(adjust['saturation'], 0),
        exposure: _double(adjust['exposure'], 0),
        temperature: _double(adjust['temperature'], 0),
        highlights: _double(adjust['highlights'], 0),
        shadows: _double(adjust['shadows'], 0),
      ),
      transition: ClipTransition(
        type: _enum(TransitionType.values, transition['type'], TransitionType.none),
        duration: Duration(milliseconds: _int(transition['durationMs'], 1000)),
      ),
      effect: _enum(VideoEffect.values, j['effect'], VideoEffect.none),
      effectIntensity: _double(j['effectIntensity'], 0.6),
      audioDenoise: _enum(DenoiseLevel.values, j['audioDenoise'], DenoiseLevel.off),
      videoDenoise: _enum(DenoiseLevel.values, j['videoDenoise'], DenoiseLevel.off),
    );
  }

  static Map<String, Object?> _audio(AudioTrack a) => {
    'id': a.id,
    'name': a.name,
    'source': a.sourcePath,
    'media': encodeMedia(a.media),
    'startUs': a.start.inMicroseconds,
    'trimStartUs': a.trimStart.inMicroseconds,
    'trimEndUs': a.trimEnd.inMicroseconds,
    'volume': a.volume,
    'muted': a.muted,
  };

  static AudioTrack _decodeAudio(Map<String, Object?> j) => AudioTrack(
    id: j['id'] as String,
    name: (j['name'] as String?) ?? 'Audio',
    sourcePath: j['source'] as String,
    media: decodeMedia(_map(j['media'])),
    start: _dur(j['startUs']),
    trimStart: _dur(j['trimStartUs']),
    trimEnd: _dur(j['trimEndUs']),
    volume: _double(j['volume'], 1),
    muted: (j['muted'] as bool?) ?? false,
  );

  static Map<String, Object?> _transform(LayerTransform t) => {
    'x': t.x,
    'y': t.y,
    'scale': t.scale,
    'rotation': t.rotation,
  };

  static LayerTransform _decodeTransform(Object? raw) {
    final j = _map(raw);
    return LayerTransform(
      x: _double(j['x'], 0.5),
      y: _double(j['y'], 0.5),
      scale: _double(j['scale'], 1),
      rotation: _double(j['rotation'], 0),
    );
  }

  static Map<String, Object?> _text(TextLayer t) => {
    'id': t.id,
    'text': t.text,
    'startUs': t.start.inMicroseconds,
    'durationUs': t.duration.inMicroseconds,
    'transform': _transform(t.transform),
    'style': {
      'fontFamily': t.style.fontFamily,
      'fontSize': t.style.fontSize,
      'bold': t.style.bold,
      'italic': t.style.italic,
      'color': t.style.color,
      'backgroundColor': t.style.backgroundColor,
      'align': t.style.align.name,
      'opacity': t.style.opacity,
      'shadow': t.style.shadow,
      'strokeColor': t.style.strokeColor,
      'strokeWidth': t.style.strokeWidth,
    },
  };

  static TextLayer _decodeText(Map<String, Object?> j) {
    final s = _map(j['style']);
    return TextLayer(
      id: j['id'] as String,
      text: (j['text'] as String?) ?? '',
      start: _dur(j['startUs']),
      duration: _dur(j['durationUs']),
      transform: _decodeTransform(j['transform']),
      style: TextLayerStyle(
        fontFamily: s['fontFamily'] as String?,
        fontSize: _double(s['fontSize'], 0.06),
        bold: (s['bold'] as bool?) ?? true,
        italic: (s['italic'] as bool?) ?? false,
        color: _int(s['color'], 0xFFFFFFFF),
        backgroundColor: s['backgroundColor'] as int?,
        align: _enum(TextAlignOption.values, s['align'], TextAlignOption.center),
        opacity: _double(s['opacity'], 1),
        shadow: (s['shadow'] as bool?) ?? true,
        strokeColor: _int(s['strokeColor'], 0xFF000000),
        strokeWidth: _double(s['strokeWidth'], 0),
      ),
    );
  }

  static Map<String, Object?> _sticker(StickerLayer s) => {
    'id': s.id,
    'kind': s.sticker.kind.name,
    'value': s.sticker.storageValue,
    'color': s.sticker.color,
    'startUs': s.start.inMicroseconds,
    'durationUs': s.duration.inMicroseconds,
    'transform': _transform(s.transform),
    'opacity': s.opacity,
  };

  static StickerLayer _decodeSticker(Map<String, Object?> j) => StickerLayer(
    id: j['id'] as String,
    sticker: StickerSpec.fromStorage(
      (j['kind'] as String?) ?? StickerKind.emoji.name,
      (j['value'] as String?) ?? '⭐',
      _int(j['color'], 0xFFFFD166),
    ),
    start: _dur(j['startUs']),
    duration: _dur(j['durationUs']),
    transform: _decodeTransform(j['transform']),
    opacity: _double(j['opacity'], 1),
  );

  static Map<String, Object?> _pip(PipLayer p) => {
    'id': p.id,
    'source': p.sourcePath,
    'media': encodeMedia(p.media),
    'startUs': p.start.inMicroseconds,
    'trimStartUs': p.trimStart.inMicroseconds,
    'trimEndUs': p.trimEnd.inMicroseconds,
    'transform': _transform(p.transform),
    'volume': p.volume,
    'muted': p.muted,
  };

  static PipLayer _decodePip(Map<String, Object?> j) => PipLayer(
    id: j['id'] as String,
    sourcePath: j['source'] as String,
    media: decodeMedia(_map(j['media'])),
    start: _dur(j['startUs']),
    trimStart: _dur(j['trimStartUs']),
    trimEnd: _dur(j['trimEndUs']),
    transform: _decodeTransform(j['transform']),
    volume: _double(j['volume'], 1),
    muted: (j['muted'] as bool?) ?? false,
  );

  // --- Lenient readers ------------------------------------------------------------

  static Map<String, Object?> _map(Object? v) => v is Map ? v.cast<String, Object?>() : const {};

  static List<Map<String, Object?>> _maps(Object? v) => v is List
      ? v.whereType<Map<dynamic, dynamic>>().map((m) => m.cast<String, Object?>()).toList()
      : const [];

  static List<T> _list<T>(Object? v) => v is List ? v.whereType<T>().toList() : <T>[];

  static int _int(Object? v, int fallback) => v is num ? v.toInt() : fallback;

  static double _double(Object? v, double fallback) => v is num ? v.toDouble() : fallback;

  static Duration _dur(Object? us) => Duration(microseconds: us is num ? us.toInt() : 0);

  static DateTime _date(Object? v) => (v is String ? DateTime.tryParse(v) : null) ?? DateTime.now();

  static T _enum<T extends Enum>(List<T> values, Object? name, T fallback) =>
      values.where((e) => e.name == name).firstOrNull ?? fallback;
}
