import 'package:flutter/material.dart';

import '../../core/constants/app_constants.dart';

class PrivacyScreen extends StatelessWidget {
  const PrivacyScreen({super.key});

  @override
  Widget build(BuildContext context) {
    const points = [
      (
        Icons.phone_android,
        'On-device processing',
        'Trimming, effects, exports and conversions run entirely on your phone.',
      ),
      (
        Icons.cloud_off,
        'No uploads',
        'Your videos, audio and projects are never sent to a server. The app works without an internet connection.',
      ),
      (
        Icons.person_off_outlined,
        'No account',
        'There is no sign-up or login, and no analytics about your media.',
      ),
      (
        Icons.lock_outline,
        'Minimal permissions',
        'Videos are imported with the system picker, which only shares the files you choose. '
            'Camera and microphone are requested only when you open the in-app camera, and '
            'gallery access only when you save an export to your gallery.',
      ),
      (
        Icons.delete_outline,
        'You stay in control',
        'Deleting a project or export removes its files from the device. '
            'Uninstalling the app removes all app data.',
      ),
    ];
    return Scaffold(
      appBar: AppBar(title: const Text('Privacy')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Row(
                children: [
                  Icon(
                    Icons.verified_user_outlined,
                    color: Theme.of(context).colorScheme.primary,
                    size: 36,
                  ),
                  const SizedBox(width: 16),
                  const Expanded(
                    child: Text(
                      AppConstants.privacyStatement,
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          for (final (icon, title, body) in points)
            ListTile(leading: Icon(icon), title: Text(title), subtitle: Text(body)),
        ],
      ),
    );
  }
}
