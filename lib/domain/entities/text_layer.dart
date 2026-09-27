import 'layer_transform.dart';
import 'timeline_item.dart';

enum TextAlignOption { left, center, right }

/// Fonts bundled with the app (see pubspec). `null` family = platform font.
class FontOption {
  const FontOption(this.label, this.family);
  final String label;
  final String? family;

  static const all = [
    FontOption('Default', null),
    FontOption('Bebas', 'BebasNeue'),
    FontOption('Oswald', 'Oswald'),
    FontOption('Playfair', 'PlayfairDisplay'),
    FontOption('Mono', 'RobotoMono'),
    FontOption('Pacifico', 'Pacifico'),
    FontOption('Lobster', 'Lobster'),
    FontOption('Marker', 'PermanentMarker'),
  ];
}

class TextLayerStyle {
  const TextLayerStyle({
    this.fontFamily,
    this.fontSize = 0.06,
    this.bold = true,
    this.italic = false,
    this.color = 0xFFFFFFFF,
    this.backgroundColor,
    this.align = TextAlignOption.center,
    this.opacity = 1.0,
    this.shadow = true,
    this.strokeColor = 0xFF000000,
    this.strokeWidth = 0.0,
  });

  final String? fontFamily;

  /// Font size as a fraction of the canvas height, so text keeps its
  /// relative size across preview and every export resolution.
  final double fontSize;
  final bool bold;
  final bool italic;

  /// ARGB colours.
  final int color;
  final int? backgroundColor;
  final TextAlignOption align;
  final double opacity;
  final bool shadow;
  final int strokeColor;

  /// Outline width as a fraction of the font size (0 = no outline).
  final double strokeWidth;

  TextLayerStyle copyWith({
    Object? fontFamily = _keep,
    double? fontSize,
    bool? bold,
    bool? italic,
    int? color,
    Object? backgroundColor = _keep,
    TextAlignOption? align,
    double? opacity,
    bool? shadow,
    int? strokeColor,
    double? strokeWidth,
  }) => TextLayerStyle(
    fontFamily: identical(fontFamily, _keep) ? this.fontFamily : fontFamily as String?,
    fontSize: fontSize ?? this.fontSize,
    bold: bold ?? this.bold,
    italic: italic ?? this.italic,
    color: color ?? this.color,
    backgroundColor: identical(backgroundColor, _keep)
        ? this.backgroundColor
        : backgroundColor as int?,
    align: align ?? this.align,
    opacity: opacity ?? this.opacity,
    shadow: shadow ?? this.shadow,
    strokeColor: strokeColor ?? this.strokeColor,
    strokeWidth: strokeWidth ?? this.strokeWidth,
  );
}

const _keep = Object();

class TextLayer implements TimelineItem {
  const TextLayer({
    required this.id,
    required this.text,
    required this.start,
    required this.duration,
    this.style = const TextLayerStyle(),
    this.transform = const LayerTransform(),
  });

  @override
  final String id;
  final String text;
  @override
  final Duration start;
  @override
  final Duration duration;
  final TextLayerStyle style;
  final LayerTransform transform;

  TextLayer copyWith({
    String? text,
    Duration? start,
    Duration? duration,
    TextLayerStyle? style,
    LayerTransform? transform,
  }) => TextLayer(
    id: id,
    text: text ?? this.text,
    start: start ?? this.start,
    duration: duration ?? this.duration,
    style: style ?? this.style,
    transform: transform ?? this.transform,
  );
}
