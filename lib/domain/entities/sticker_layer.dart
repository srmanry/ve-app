import 'layer_transform.dart';
import 'timeline_item.dart';

/// [image] is a user logo/watermark (PNG, transparency kept).
enum StickerKind { emoji, shape, image }

/// Vector shapes drawn by `OverlayPainter` - no downloaded assets needed.
enum StickerShape {
  circle,
  ring,
  square,
  roundedSquare,
  triangle,
  star,
  heart,
  sparkle,
  arrowRight,
  arrowLeft,
  arrowUp,
  arrowDown,
  speechBubble,
  check,
  cross,
  banner,
}

/// Identifies what a sticker draws.
class StickerSpec {
  const StickerSpec.emoji(this.value) : kind = StickerKind.emoji, color = 0xFFFFFFFF;

  const StickerSpec.shape(StickerShape shape, {this.color = 0xFFFFD166})
    : kind = StickerKind.shape,
      value = shape;

  /// A logo image; [relativePath] is relative to the app data directory.
  const StickerSpec.image(String relativePath)
    : kind = StickerKind.image,
      value = relativePath,
      color = 0xFFFFFFFF;

  const StickerSpec._(this.kind, this.value, this.color);

  bool get isImage => kind == StickerKind.image;

  factory StickerSpec.fromStorage(String kind, String value, int color) {
    if (kind == StickerKind.shape.name) {
      final shape = StickerShape.values.where((s) => s.name == value).firstOrNull;
      return StickerSpec._(StickerKind.shape, shape ?? StickerShape.star, color);
    }
    if (kind == StickerKind.image.name) return StickerSpec.image(value);
    return StickerSpec._(StickerKind.emoji, value, color);
  }

  final StickerKind kind;

  /// Emoji string for [StickerKind.emoji], [StickerShape] for shapes.
  final Object value;

  /// Fill colour (ARGB) for shapes.
  final int color;

  String get storageValue => value is StickerShape ? (value as StickerShape).name : value as String;

  StickerSpec withColor(int color) => StickerSpec._(kind, value, color);

  /// The built-in local sticker catalogue.
  static const emojis = [
    '😀',
    '😂',
    '🥰',
    '😎',
    '🤩',
    '😮',
    '😢',
    '😡',
    '👍',
    '👏',
    '🙌',
    '🔥',
    '💯',
    '❤️',
    '💔',
    '⭐',
    '✨',
    '🎉',
    '🎂',
    '🎵',
    '📍',
    '⚡',
    '🌈',
    '☀️',
    '🌙',
    '🌸',
    '🍕',
    '☕',
    '🚀',
    '🎬',
    '📸',
    '👀',
  ];

  static const shapes = StickerShape.values;
}

class StickerLayer implements TimelineItem {
  const StickerLayer({
    required this.id,
    required this.sticker,
    required this.start,
    required this.duration,
    this.transform = const LayerTransform(),
    this.opacity = 1.0,
  });

  @override
  final String id;
  final StickerSpec sticker;
  @override
  final Duration start;
  @override
  final Duration duration;

  /// [LayerTransform.scale] = 1 renders the sticker at 20% of the canvas'
  /// shorter side.
  final LayerTransform transform;
  final double opacity;

  StickerLayer copyWith({
    StickerSpec? sticker,
    Duration? start,
    Duration? duration,
    LayerTransform? transform,
    double? opacity,
  }) => StickerLayer(
    id: id,
    sticker: sticker ?? this.sticker,
    start: start ?? this.start,
    duration: duration ?? this.duration,
    transform: transform ?? this.transform,
    opacity: opacity ?? this.opacity,
  );
}
