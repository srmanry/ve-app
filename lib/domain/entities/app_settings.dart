import 'export_settings.dart';

enum AppThemeMode { dark, light, system }

class AppSettings {
  const AppSettings({
    this.defaultExport = const ExportSettings(),
    this.themeMode = AppThemeMode.dark,
    this.onboardingCompleted = false,
  });

  final ExportSettings defaultExport;
  final AppThemeMode themeMode;
  final bool onboardingCompleted;

  AppSettings copyWith({
    ExportSettings? defaultExport,
    AppThemeMode? themeMode,
    bool? onboardingCompleted,
  }) => AppSettings(
    defaultExport: defaultExport ?? this.defaultExport,
    themeMode: themeMode ?? this.themeMode,
    onboardingCompleted: onboardingCompleted ?? this.onboardingCompleted,
  );
}
