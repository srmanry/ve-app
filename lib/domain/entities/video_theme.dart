import 'color_adjustments.dart';
import 'transition.dart';
import 'video_effect.dart';

/// A one-tap style for a whole video: look (filter + effect), pacing (photo
/// length + transition) and title typography. Applying a theme only sets
/// ordinary clip/layer settings, so everything stays editable afterwards.
enum VideoTheme {
  classic(
    'Classic',
    filter: FilterPreset.original,
    transition: TransitionType.fade,
    transitionMs: 600,
    photoMs: 3000,
    titleFont: 'PlayfairDisplay',
    titleColor: 0xFFFFFFFF,
  ),
  vintage(
    'Vintage',
    filter: FilterPreset.vintage,
    effect: VideoEffect.grain,
    effectIntensity: 0.35,
    transition: TransitionType.crossDissolve,
    transitionMs: 1000,
    photoMs: 3500,
    titleFont: 'Lobster',
    titleColor: 0xFFFFF1D6,
  ),
  cinematic(
    'Cinematic',
    filter: FilterPreset.contrast,
    filterStrength: 0.7,
    effect: VideoEffect.vignette,
    effectIntensity: 0.55,
    transition: TransitionType.fade,
    transitionMs: 1000,
    photoMs: 4000,
    titleFont: 'BebasNeue',
    titleColor: 0xFFFFFFFF,
    titleSize: 0.1,
  ),
  travel(
    'Travel',
    filter: FilterPreset.saturation,
    transition: TransitionType.slide,
    transitionMs: 500,
    photoMs: 2500,
    titleFont: 'PermanentMarker',
    titleColor: 0xFFFFD166,
  ),
  party(
    'Party',
    filter: FilterPreset.saturation,
    effect: VideoEffect.glitch,
    effectIntensity: 0.25,
    transition: TransitionType.zoom,
    transitionMs: 500,
    photoMs: 1500,
    titleFont: 'BebasNeue',
    titleColor: 0xFFFF4FA3,
    titleSize: 0.1,
  ),
  romantic(
    'Romantic',
    filter: FilterPreset.warm,
    transition: TransitionType.crossDissolve,
    transitionMs: 1500,
    photoMs: 4000,
    titleFont: 'Pacifico',
    titleColor: 0xFFFFC2D6,
  ),
  blackWhite(
    'Black & White',
    filter: FilterPreset.grayscale,
    effect: VideoEffect.vignette,
    effectIntensity: 0.4,
    transition: TransitionType.fade,
    transitionMs: 1000,
    photoMs: 3500,
    titleFont: 'Oswald',
    titleColor: 0xFFFFFFFF,
  ),
  coolBreeze(
    'Cool Breeze',
    filter: FilterPreset.cool,
    transition: TransitionType.slide,
    transitionMs: 700,
    photoMs: 3000,
    titleFont: 'Oswald',
    titleColor: 0xFFD6F1FF,
  ),
  dreamy(
    'Dreamy',
    filter: FilterPreset.brightness,
    filterStrength: 0.6,
    effect: VideoEffect.blur,
    effectIntensity: 0.08,
    transition: TransitionType.crossDissolve,
    transitionMs: 1500,
    photoMs: 4000,
    titleFont: 'Pacifico',
    titleColor: 0xFFFFFFFF,
  ),
  retro(
    'Retro',
    filter: FilterPreset.sepia,
    filterStrength: 0.6,
    effect: VideoEffect.glitch,
    effectIntensity: 0.35,
    transition: TransitionType.slide,
    transitionMs: 500,
    photoMs: 2500,
    titleFont: 'RobotoMono',
    titleColor: 0xFFFFE066,
  );

  const VideoTheme(
    this.label, {
    required this.filter,
    this.filterStrength = 1.0,
    this.effect = VideoEffect.none,
    this.effectIntensity = 0.6,
    required this.transition,
    required this.transitionMs,
    required this.photoMs,
    required this.titleFont,
    required this.titleColor,
    this.titleSize = 0.075,
  });

  final String label;
  final FilterPreset filter;
  final double filterStrength;
  final VideoEffect effect;
  final double effectIntensity;
  final TransitionType transition;
  final int transitionMs;

  /// How long each photo shows.
  final int photoMs;

  /// Bundled font family for the title/ending text.
  final String titleFont;
  final int titleColor;

  /// Font size as a fraction of the canvas height.
  final double titleSize;

  Duration get photoDuration => Duration(milliseconds: photoMs);
  ClipTransition get clipTransition => ClipTransition(
    type: transition,
    duration: Duration(milliseconds: transitionMs),
  );
}
