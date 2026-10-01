import 'color_adjustments.dart';

/// Output formats of the image tools.
enum ImageFormat {
  jpg('JPG', 'jpg', 'Smallest photos, no transparency'),
  png('PNG', 'png', 'Lossless, keeps transparency (large)'),
  webp('WebP', 'webp', 'Small and keeps transparency');

  const ImageFormat(this.label, this.extension, this.hint);
  final String label;
  final String extension;
  final String hint;

  /// PNG is lossless, so it has no quality setting.
  bool get hasQuality => this != png;
  bool get keepsTransparency => this != jpg;
}

/// Crop frame shapes. [ratio] is width / height; null = free.
enum CropAspect {
  free('Free', null),
  original('Original', null),
  square('1:1', 1),
  portrait45('4:5', 4 / 5),
  portrait34('3:4', 3 / 4),
  story('9:16', 9 / 16),
  landscape43('4:3', 4 / 3),
  wide('16:9', 16 / 9);

  const CropAspect(this.label, this.ratio);
  final String label;
  final double? ratio;
}

/// Crop rectangle in 0 … 1 fractions of the (rotated) photo.
class CropRect {
  const CropRect(this.left, this.top, this.right, this.bottom);
  static const full = CropRect(0, 0, 1, 1);

  final double left;
  final double top;
  final double right;
  final double bottom;

  double get width => right - left;
  double get height => bottom - top;
  bool get isFull => left <= 0 && top <= 0 && right >= 1 && bottom >= 1;

  /// Largest centred rect with pixel aspect [ratio] on a [w]×[h] photo.
  static CropRect centered(double ratio, double w, double h) {
    final photo = w / h;
    if (ratio > photo) {
      final fh = photo / ratio;
      return CropRect(0, (1 - fh) / 2, 1, (1 + fh) / 2);
    }
    final fw = ratio / photo;
    return CropRect((1 - fw) / 2, 0, (1 + fw) / 2, 1);
  }

  @override
  bool operator ==(Object other) =>
      other is CropRect &&
      other.left == left &&
      other.top == top &&
      other.right == right &&
      other.bottom == bottom;

  @override
  int get hashCode => Object.hash(left, top, right, bottom);
}

/// What goes behind the person after background removal.
enum CutoutBackground { transparent, white, color, blur }

/// A logo/watermark on a photo.
class ImageLogo {
  const ImageLogo({
    required this.path,
    this.x = 0.85,
    this.y = 0.12,
    this.size = 0.22,
    this.opacity = 0.9,
  });

  /// Absolute path of the logo PNG.
  final String path;

  /// Centre, 0 … 1 of the output.
  final double x;
  final double y;

  /// Width as a fraction of the output's shorter side.
  final double size;
  final double opacity;

  ImageLogo copyWith({double? x, double? y, double? size, double? opacity}) => ImageLogo(
    path: path,
    x: x ?? this.x,
    y: y ?? this.y,
    size: size ?? this.size,
    opacity: opacity ?? this.opacity,
  );
}

/// Brush tools of the Retouch tab.
enum RetouchTool {
  heal('Heal', 'Tap a spot or blemish to remove it'),
  smooth('Smooth', 'Paint over skin to soften it'),
  brighten('Brighten', 'Paint to lighten an area'),
  darken('Darken', 'Paint to deepen shadows'),
  whiten('Whiten', 'Paint over teeth or eyes'),
  blur('Blur', 'Paint to hide faces, plates, text');

  const RetouchTool(this.label, this.hint);
  final String label;
  final String hint;

  bool get hasStrength => this != heal;
}

/// One brush stroke (or, for [RetouchTool.heal], a set of spots).
/// Coordinates are fractions of the *source* photo, so strokes follow
/// rotation and crop and work at any resolution.
class RetouchStroke {
  const RetouchStroke({
    required this.tool,
    required this.points,
    required this.radius,
    this.strength = 0.6,
  });

  final RetouchTool tool;
  final List<(double, double)> points;

  /// Brush radius as a fraction of the photo's longer side.
  final double radius;

  /// 0 … 1.
  final double strength;
}

/// Fonts offered for text on photos (bundled, see pubspec).
const photoFonts = [
  'Poppins',
  'BebasNeue',
  'Oswald',
  'PlayfairDisplay',
  'Pacifico',
  'Lobster',
  'PermanentMarker',
  'RobotoMono',
];

/// A text label on the photo.
class PhotoText {
  const PhotoText({
    required this.id,
    required this.text,
    this.x = 0.5,
    this.y = 0.5,
    this.size = 0.08,
    this.color = 0xFFFFFFFF,
    this.font = 'Poppins',
    this.bold = true,
    this.shadow = true,
    this.background = false,
  });

  final String id;
  final String text;

  /// Centre, 0 … 1 of the output.
  final double x;
  final double y;

  /// Font size as a fraction of the output's shorter side.
  final double size;
  final int color;
  final String font;
  final bool bold;
  final bool shadow;

  /// Rounded box behind the text.
  final bool background;

  PhotoText copyWith({
    String? text,
    double? x,
    double? y,
    double? size,
    int? color,
    String? font,
    bool? bold,
    bool? shadow,
    bool? background,
  }) => PhotoText(
    id: id,
    text: text ?? this.text,
    x: x ?? this.x,
    y: y ?? this.y,
    size: size ?? this.size,
    color: color ?? this.color,
    font: font ?? this.font,
    bold: bold ?? this.bold,
    shadow: shadow ?? this.shadow,
    background: background ?? this.background,
  );
}

/// Every edit of the photo editor. Rendering lives in `ImageRenderer`, used
/// for both the preview and the saved file.
class ImageEdit {
  const ImageEdit({
    this.quarterTurns = 0,
    this.flipX = false,
    this.flipY = false,
    this.crop = CropRect.full,
    this.aspect = CropAspect.free,
    this.filter = FilterPreset.original,
    this.filterStrength = 1,
    this.adjustments = ColorAdjustments.neutral,
    this.logo,
    this.cutout = false,
    this.background = CutoutBackground.transparent,
    this.backgroundColor = 0xFFFFFFFF,
    this.retouch = const [],
    this.texts = const [],
    this.vignette = 0,
  });

  /// Clockwise 90° turns, 0 … 3.
  final int quarterTurns;
  final bool flipX;
  final bool flipY;
  final CropRect crop;
  final CropAspect aspect;
  final FilterPreset filter;
  final double filterStrength;
  final ColorAdjustments adjustments;
  final ImageLogo? logo;

  /// Background removed (needs a person mask).
  final bool cutout;
  final CutoutBackground background;
  final int backgroundColor;

  /// Brush strokes and healed spots, in the order they were made.
  final List<RetouchStroke> retouch;
  final List<PhotoText> texts;

  /// Darkened corners, 0 … 1.
  final double vignette;

  /// Healed spots (applied to the pixels before anything else).
  Iterable<RetouchStroke> get heals => retouch.where((s) => s.tool == RetouchTool.heal);

  bool get swapsAxes => quarterTurns.isOdd;

  bool get hasTransparency => cutout && background == CutoutBackground.transparent;

  ImageEdit copyWith({
    int? quarterTurns,
    bool? flipX,
    bool? flipY,
    CropRect? crop,
    CropAspect? aspect,
    FilterPreset? filter,
    double? filterStrength,
    ColorAdjustments? adjustments,
    ImageLogo? logo,
    bool clearLogo = false,
    bool? cutout,
    CutoutBackground? background,
    int? backgroundColor,
    List<RetouchStroke>? retouch,
    List<PhotoText>? texts,
    double? vignette,
  }) => ImageEdit(
    quarterTurns: quarterTurns ?? this.quarterTurns,
    flipX: flipX ?? this.flipX,
    flipY: flipY ?? this.flipY,
    crop: crop ?? this.crop,
    aspect: aspect ?? this.aspect,
    filter: filter ?? this.filter,
    filterStrength: filterStrength ?? this.filterStrength,
    adjustments: adjustments ?? this.adjustments,
    logo: clearLogo ? null : (logo ?? this.logo),
    cutout: cutout ?? this.cutout,
    background: background ?? this.background,
    backgroundColor: backgroundColor ?? this.backgroundColor,
    retouch: retouch ?? this.retouch,
    texts: texts ?? this.texts,
    vignette: vignette ?? this.vignette,
  );

  /// Maps a point of the output (0 … 1, after rotate/flip/crop) back to the
  /// source photo (0 … 1). Brush strokes are stored in source space.
  (double, double) sourceFromOutput(double u, double v) {
    // Output → rotated photo.
    final ox = crop.left + u * crop.width;
    final oy = crop.top + v * crop.height;
    // Undo the clockwise turns.
    var (fx, fy) = switch (quarterTurns % 4) {
      1 => (oy, 1 - ox),
      2 => (1 - ox, 1 - oy),
      3 => (1 - oy, ox),
      _ => (ox, oy),
    };
    // Flips happen in source space, before the rotation.
    if (flipX) fx = 1 - fx;
    if (flipY) fy = 1 - fy;
    return (fx, fy);
  }
}

/// Resize choices of the batch Resize tool.
enum ResizePreset {
  half('50%', scale: 0.5),
  threeQuarter('75%', scale: 0.75),
  hd('1280 px', longSide: 1280),
  fullHd('1920 px', longSide: 1920),
  insta('1080 px', longSide: 1080),
  small('800 px', longSide: 800);

  const ResizePreset(this.label, {this.scale, this.longSide});
  final String label;
  final double? scale;
  final int? longSide;

  /// Target size for a [w]×[h] photo (never upscaled, even dimensions).
  (int, int) apply(int w, int h) =>
      longSide != null ? fitLongSide(w, h, longSide!) : scaleSize(w, h, scale!);
}

/// [w]×[h] scaled so the long side is at most [px] (never upscaled).
(int, int) fitLongSide(int w, int h, int px) => scaleSize(w, h, px / (w > h ? w : h));

/// [w]×[h] scaled by [f] (capped at 1), rounded to even pixels.
(int, int) scaleSize(int w, int h, double f) {
  final k = f > 1 ? 1.0 : f;
  int even(double v) => ((v / 2).round() * 2).clamp(2, 1 << 20);
  return (even(w * k), even(h * k));
}

enum SizeUnit {
  px('px'),
  mm('mm'),
  inch('inch');

  const SizeUnit(this.label);
  final String label;
}

/// Print resolution used to turn mm / inch sizes into pixels.
const printDpi = 300;

/// Pixels for [value] in [unit] at [printDpi].
int toPixels(double value, SizeUnit unit) => switch (unit) {
  SizeUnit.px => value.round(),
  SizeUnit.mm => (value / 25.4 * printDpi).round(),
  SizeUnit.inch => (value * printDpi).round(),
};

/// An exact output size. With [fill] the photo is cropped to the shape
/// (vertical position [anchorY]: 0 = keep the top, 0.5 = centre); otherwise
/// it is scaled to fit inside.
class ResizeTarget {
  const ResizeTarget({
    required this.width,
    required this.height,
    this.fill = true,
    this.anchorY = 0.5,
    this.dpi,
    this.maxBytes,
  });

  final int width;
  final int height;
  final bool fill;
  final double anchorY;

  /// Print resolution written into the file (JPG / PNG), if any.
  final int? dpi;

  /// The file is re-encoded at lower quality until it fits (JPG / WebP).
  final int? maxBytes;

  /// Final pixel size for a [w]×[h] photo.
  (int, int) sizeFor(int w, int h) {
    if (fill) return (width, height);
    // Fit inside the box, keeping the shape.
    final f = (width / w) < (height / h) ? width / w : height / h;
    return (((w * f).round()).clamp(1, 1 << 20), ((h * f).round()).clamp(1, 1 << 20));
  }
}

/// Standard photo sizes (ID photos, prints, online application forms).
enum PhotoSizePreset {
  passport('Passport / NID', 'e-Passport, NID, visa, govt. job forms', 45, 55, SizeUnit.mm, id: true),
  square2in('2×2 inch / US visa', 'US visa & DV lottery (white background)', 2, 2, SizeUnit.inch, id: true),
  stamp('Stamp size', 'Admission, exam registration, bank forms', 20, 25, SizeUnit.mm, id: true),
  jobPhoto('Online form photo', 'Teletalk, BCS & online forms · max 100 KB', 300, 300, SizeUnit.px,
      id: true, maxKb: 100),
  signature('Signature', 'Online form signature · max 60 KB', 300, 80, SizeUnit.px, maxKb: 60),
  print3r('3R print', 'Lab print, portfolio, album', 3.5, 5, SizeUnit.inch, followsPhoto: true),
  print4r('4R print', 'Most popular photo print', 4, 6, SizeUnit.inch, followsPhoto: true);

  const PhotoSizePreset(
    this.label,
    this.usage,
    this.w,
    this.h,
    this.unit, {
    this.id = false,
    this.maxKb,
    this.followsPhoto = false,
  });

  final String label;
  final String usage;
  final double w;
  final double h;
  final SizeUnit unit;

  /// ID photo: crop keeps more of the top (the head).
  final bool id;
  final int? maxKb;

  /// Prints turn landscape for landscape photos.
  final bool followsPhoto;

  String get sizeLabel {
    String n(double v) => v == v.roundToDouble() ? v.toInt().toString() : v.toString();
    final px = '${toPixels(w, unit)}×${toPixels(h, unit)} px';
    return unit == SizeUnit.px ? px : '${n(w)}×${n(h)} ${unit.label} · $px';
  }

  ResizeTarget targetFor(int photoW, int photoH) {
    var pw = toPixels(w, unit), ph = toPixels(h, unit);
    if (followsPhoto && photoW > photoH) (pw, ph) = (ph, pw);
    return ResizeTarget(
      width: pw,
      height: ph,
      anchorY: id ? 0.25 : 0.5,
      dpi: unit == SizeUnit.px ? null : printDpi,
      maxBytes: maxKb == null ? null : maxKb! * 1024,
    );
  }
}
