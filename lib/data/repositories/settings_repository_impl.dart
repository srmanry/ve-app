import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../domain/entities/app_settings.dart';
import '../models/project_json.dart';
import '../../domain/repositories/settings_repository.dart';

class SettingsRepositoryImpl implements SettingsRepository {
  SettingsRepositoryImpl(this._prefs);

  final SharedPreferences _prefs;

  static const _kExport = 'settings.defaultExport';
  static const _kTheme = 'settings.theme';
  static const _kOnboarding = 'settings.onboardingCompleted';

  @override
  AppSettings load() {
    var export = const AppSettings().defaultExport;
    final raw = _prefs.getString(_kExport);
    if (raw != null) {
      try {
        final json = jsonDecode(raw);
        if (json is Map) {
          export = ProjectJson.decodeExportSettings(json.cast<String, Object?>());
        }
      } on FormatException {
        // Keep defaults.
      }
    }
    final theme =
        AppThemeMode.values.where((m) => m.name == _prefs.getString(_kTheme)).firstOrNull ??
        AppThemeMode.dark;
    return AppSettings(
      defaultExport: export,
      themeMode: theme,
      onboardingCompleted: _prefs.getBool(_kOnboarding) ?? false,
    );
  }

  @override
  Future<void> save(AppSettings settings) async {
    await _prefs.setString(
      _kExport,
      jsonEncode(ProjectJson.encodeExportSettings(settings.defaultExport)),
    );
    await _prefs.setString(_kTheme, settings.themeMode.name);
    await _prefs.setBool(_kOnboarding, settings.onboardingCompleted);
  }
}
