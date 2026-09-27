import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/constants/app_constants.dart';
import '../core/theme/app_theme.dart';
import '../domain/entities/app_settings.dart';
import '../presentation/onboarding/onboarding_screen.dart';
import '../presentation/shell/app_shell.dart';
import 'providers.dart';

class VideoEditorApp extends ConsumerWidget {
  const VideoEditorApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(settingsProvider.select((s) => s.themeMode));
    final onboarded = ref.watch(settingsProvider.select((s) => s.onboardingCompleted));
    return MaterialApp(
      title: AppConstants.appName,
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: switch (themeMode) {
        AppThemeMode.dark => ThemeMode.dark,
        AppThemeMode.light => ThemeMode.light,
        AppThemeMode.system => ThemeMode.system,
      },
      home: onboarded ? const AppShell() : const OnboardingScreen(),
    );
  }
}
