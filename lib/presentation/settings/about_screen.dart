import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../core/constants/app_constants.dart';

class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  static const version = '1.0.0';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('About')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const SizedBox(height: 12),
          const Icon(Icons.movie_filter_rounded, size: 64),
          const SizedBox(height: 12),
          Text(
            AppConstants.appName,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const Text('Version $version', textAlign: TextAlign.center),
          const SizedBox(height: 8),
          Text(
            AppConstants.appTagline,
            textAlign: TextAlign.center,
            style: TextStyle(color: context.mutedColor),
          ),
          const SizedBox(height: 24),
          const ListTile(
            leading: Icon(Icons.memory),
            title: Text('Video engine'),
            subtitle: Text('FFmpeg (via FFmpegKit), running locally on your device.'),
          ),
          ListTile(
            leading: const Icon(Icons.description_outlined),
            title: const Text('Open-source licenses'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => showLicensePage(
              context: context,
              applicationName: AppConstants.appName,
              applicationVersion: version,
            ),
          ),
        ],
      ),
    );
  }
}
