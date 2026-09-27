import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/providers.dart';
import '../../core/constants/app_constants.dart';
import '../../domain/entities/app_settings.dart';
import '../../domain/entities/export_settings.dart';
import '../widgets/app_dialogs.dart';
import 'about_screen.dart';
import 'privacy_screen.dart';
import 'storage_screen.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  static String get _storeUrl => Platform.isIOS
      ? 'https://apps.apple.com/app/id${AppConstants.iosAppStoreId}'
      : 'https://play.google.com/store/apps/details?id=${AppConstants.androidPackageId}';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final controller = ref.read(settingsProvider.notifier);
    final export = settings.defaultExport;

    void setExport(ExportSettings s) => controller.update((a) => a.copyWith(defaultExport: s));

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          const _Section('Export defaults'),
          _ChoiceTile<ExportResolution>(
            icon: Icons.high_quality_outlined,
            title: 'Default resolution',
            value: export.resolution,
            values: ExportResolution.values,
            label: (v) => v.label,
            onChanged: (v) => setExport(export.copyWith(resolution: v)),
          ),
          _ChoiceTile<ExportQuality>(
            icon: Icons.tune,
            title: 'Default quality',
            value: export.quality,
            values: ExportQuality.values.where((q) => q != ExportQuality.custom).toList(),
            label: (v) => v.label,
            onChanged: (v) => setExport(export.copyWith(quality: v)),
          ),
          _ChoiceTile<int>(
            icon: Icons.slow_motion_video,
            title: 'Default frame rate',
            value: export.frameRate,
            values: ExportSettings.frameRates,
            label: (v) => '$v fps',
            onChanged: (v) => setExport(export.copyWith(frameRate: v)),
          ),
          const _Section('Appearance'),
          _ChoiceTile<AppThemeMode>(
            icon: Icons.dark_mode_outlined,
            title: 'Theme',
            value: settings.themeMode,
            values: AppThemeMode.values,
            label: (v) => switch (v) {
              AppThemeMode.dark => 'Dark',
              AppThemeMode.light => 'Light',
              AppThemeMode.system => 'System',
            },
            onChanged: (v) => controller.update((a) => a.copyWith(themeMode: v)),
          ),
          const ListTile(
            leading: Icon(Icons.language),
            title: Text('Language'),
            subtitle: Text('English (more languages planned)'),
          ),
          const _Section('Storage'),
          ListTile(
            leading: const Icon(Icons.sd_storage_outlined),
            title: const Text('Storage usage'),
            subtitle: const Text('Exports, projects, cache and temporary files'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () =>
                Navigator.push(context, MaterialPageRoute(builder: (_) => const StorageScreen())),
          ),
          ListTile(
            leading: const Icon(Icons.cleaning_services_outlined),
            title: const Text('Clear temporary files'),
            onTap: () async {
              await ref.read(storageServiceProvider).clearTemporaryFiles();
              if (context.mounted) showSnack(context, 'Temporary files cleared');
            },
          ),
          const _Section('About'),
          ListTile(
            leading: const Icon(Icons.privacy_tip_outlined),
            title: const Text('Privacy'),
            subtitle: const Text(AppConstants.privacyStatement, maxLines: 2),
            trailing: const Icon(Icons.chevron_right),
            onTap: () =>
                Navigator.push(context, MaterialPageRoute(builder: (_) => const PrivacyScreen())),
          ),
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('About'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () =>
                Navigator.push(context, MaterialPageRoute(builder: (_) => const AboutScreen())),
          ),
          ListTile(
            leading: const Icon(Icons.star_outline),
            title: const Text('Rate app'),
            subtitle: const Text('Opens the app store'),
            onTap: () async {
              final ok = await launchUrl(
                Uri.parse(_storeUrl),
                mode: LaunchMode.externalApplication,
              );
              if (!ok && context.mounted) showSnack(context, 'Couldn\'t open the store.');
            },
          ),
          Builder(
            builder: (context) => ListTile(
              leading: const Icon(Icons.share_outlined),
              title: const Text('Share app'),
              onTap: () {
                final box = context.findRenderObject() as RenderBox?;
                SharePlus.instance.share(
                  ShareParams(
                    text: '${AppConstants.appName} - a private, offline video editor. $_storeUrl',
                    sharePositionOrigin: box == null
                        ? null
                        : box.localToGlobal(Offset.zero) & box.size,
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section(this.title);
  final String title;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
    child: Text(
      title.toUpperCase(),
      style: TextStyle(
        fontSize: 12,
        letterSpacing: 0.8,
        fontWeight: FontWeight.w700,
        color: Theme.of(context).colorScheme.primary,
      ),
    ),
  );
}

class _ChoiceTile<T> extends StatelessWidget {
  const _ChoiceTile({
    required this.icon,
    required this.title,
    required this.value,
    required this.values,
    required this.label,
    required this.onChanged,
  });

  final IconData icon;
  final String title;
  final T value;
  final List<T> values;
  final String Function(T) label;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) => ListTile(
    leading: Icon(icon),
    title: Text(title),
    subtitle: Text(label(value)),
    onTap: () async {
      final picked = await showModalBottomSheet<T>(
        context: context,
        builder: (context) => SafeArea(
          child: RadioGroup<T>(
            groupValue: value,
            onChanged: (v) => Navigator.pop(context, v),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [for (final v in values) RadioListTile<T>(value: v, title: Text(label(v)))],
            ),
          ),
        ),
      );
      if (picked != null) onChanged(picked);
    },
  );
}
