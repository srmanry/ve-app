import 'package:flutter/material.dart';

/// App colour palette.
///
/// The browsing/settings experience uses a warm cream and coral treatment,
/// while editing screens keep their neutral dark surfaces so media colours
/// remain accurate.
abstract final class AppColors {
  static const accent = Color(0xFFF45A2A);
  static const accentAlt = Color(0xFFFF9273);
  static const accentSoft = Color(0xFFFFE8DF);
  static const danger = Color(0xFFD93D3D);
  static const success = Color(0xFF34C77B);

  static const lightBackground = Color(0xFFFFF8F1);
  static const lightSurface = Color(0xFFFFFDFC);
  static const lightSurfaceHigh = Color(0xFFFFEEE6);
  static const lightOutline = Color(0xFFE8DCD5);
  static const lightText = Color(0xFF272321);
  static const lightTextMuted = Color(0xFF7D746F);

  static const darkBackground = Color(0xFF0E0F13);
  static const darkSurface = Color(0xFF17191F);
  static const darkSurfaceHigh = Color(0xFF20232B);
  static const darkOutline = Color(0xFF2E323C);

  // Timeline track colours.
  static const videoTrack = Color(0xFF2B3446);
  static const audioTrack = Color(0xFF1F8A70);
  static const textTrack = Color(0xFFB9770E);
  static const stickerTrack = Color(0xFFB0417A);
  static const pipTrack = Color(0xFF3F6FD8);
  static const selection = Color(0xFFFFD166);
}

abstract final class AppTheme {
  static ThemeData dark() => _build(
    ColorScheme.fromSeed(seedColor: AppColors.accent, brightness: Brightness.dark).copyWith(
      primary: AppColors.accent,
      onPrimary: Colors.white,
      secondary: AppColors.accentAlt,
      surface: AppColors.darkSurface,
      surfaceContainerHighest: AppColors.darkSurfaceHigh,
      surfaceContainerHigh: AppColors.darkSurfaceHigh,
      surfaceContainer: AppColors.darkSurface,
      outlineVariant: AppColors.darkOutline,
      error: AppColors.danger,
    ),
    scaffold: AppColors.darkBackground,
  );

  static ThemeData light() => _build(
    ColorScheme.fromSeed(
      seedColor: AppColors.accent,
      brightness: Brightness.light,
      surface: AppColors.lightSurface,
    ).copyWith(
      primary: AppColors.accent,
      onPrimary: Colors.white,
      primaryContainer: AppColors.accentSoft,
      onPrimaryContainer: const Color(0xFF7D250D),
      secondary: AppColors.accentAlt,
      onSecondary: const Color(0xFF55200F),
      secondaryContainer: const Color(0xFFFFD9CC),
      onSecondaryContainer: const Color(0xFF69230C),
      surface: AppColors.lightSurface,
      onSurface: AppColors.lightText,
      onSurfaceVariant: AppColors.lightTextMuted,
      surfaceContainerLowest: Colors.white,
      surfaceContainerLow: const Color(0xFFFFFAF6),
      surfaceContainer: const Color(0xFFFFF4ED),
      surfaceContainerHigh: AppColors.lightSurfaceHigh,
      surfaceContainerHighest: const Color(0xFFFFE5DA),
      outline: const Color(0xFFD8C8C0),
      outlineVariant: AppColors.lightOutline,
      error: AppColors.danger,
    ),
    scaffold: AppColors.lightBackground,
  );

  static ThemeData _build(ColorScheme scheme, {required Color scaffold}) {
    final base = ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      scaffoldBackgroundColor: scaffold,
      fontFamily: 'Poppins',
      visualDensity: VisualDensity.standard,
    );
    return base.copyWith(
      textTheme: base.textTheme.copyWith(
        headlineLarge: base.textTheme.headlineLarge?.copyWith(
          fontSize: 30,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.5,
        ),
        headlineMedium: base.textTheme.headlineMedium?.copyWith(
          fontSize: 26,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.4,
        ),
        headlineSmall: base.textTheme.headlineSmall?.copyWith(
          fontSize: 22,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.25,
        ),
        titleLarge: base.textTheme.titleLarge?.copyWith(
          fontSize: 20,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.2,
        ),
        titleMedium: base.textTheme.titleMedium?.copyWith(
          fontSize: 16,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.1,
        ),
        titleSmall: base.textTheme.titleSmall?.copyWith(fontSize: 14, fontWeight: FontWeight.w600),
        bodyLarge: base.textTheme.bodyLarge?.copyWith(fontSize: 16, height: 1.35),
        bodyMedium: base.textTheme.bodyMedium?.copyWith(fontSize: 14, height: 1.35),
        bodySmall: base.textTheme.bodySmall?.copyWith(fontSize: 12, height: 1.3),
        labelLarge: base.textTheme.labelLarge?.copyWith(fontSize: 14, fontWeight: FontWeight.w600),
        labelMedium: base.textTheme.labelMedium?.copyWith(
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
        labelSmall: base.textTheme.labelSmall?.copyWith(fontSize: 10, fontWeight: FontWeight.w500),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: scaffold,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: base.textTheme.titleLarge?.copyWith(
          fontWeight: FontWeight.w700,
          color: scheme.onSurface,
        ),
      ),
      cardTheme: CardThemeData(
        color: scheme.surface,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(color: scheme.outlineVariant),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          foregroundColor: Colors.white,
          iconColor: Colors.white,
          minimumSize: const Size(48, 48),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          textStyle: const TextStyle(fontFamily: 'Poppins', fontWeight: FontWeight.w600, fontSize: 15),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(48, 48),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        showDragHandle: true,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: scheme.surface,
        indicatorColor: scheme.primary,
        indicatorShape: const CircleBorder(),
        elevation: 0,
        height: 68,
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return TextStyle(
            color: selected ? scheme.primary : scheme.onSurfaceVariant,
            fontSize: 12,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
          );
        }),
        iconTheme: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return IconThemeData(color: selected ? Colors.white : scheme.onSurfaceVariant);
        }),
      ),
      listTileTheme: ListTileThemeData(
        iconColor: scheme.primary,
        textColor: scheme.onSurface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(foregroundColor: scheme.primary),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(color: scheme.primary),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: scheme.primary,
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      sliderTheme: base.sliderTheme.copyWith(
        trackHeight: 3,
        showValueIndicator: ShowValueIndicator.onDrag,
      ),
      snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
      dividerTheme: DividerThemeData(color: scheme.outlineVariant, space: 1),
    );
  }
}

extension ThemeContextX on BuildContext {
  /// Secondary text/icon colour that works in both light and dark themes.
  Color get mutedColor => Theme.of(this).colorScheme.onSurfaceVariant;
}

/// Editing screens always use the dark "studio" look, regardless of the
/// app theme, so video colours are judged against a neutral dark UI.
class StudioTheme extends StatelessWidget {
  const StudioTheme({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Theme(data: AppTheme.dark(), child: child);
}
