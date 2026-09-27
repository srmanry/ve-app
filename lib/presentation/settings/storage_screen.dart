import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../../app/providers.dart';
import '../../core/utils/formatters.dart';
import '../../domain/usecases/project_usecases.dart';
import '../../services/storage/storage_service.dart';
import '../widgets/app_dialogs.dart';

class StorageScreen extends ConsumerStatefulWidget {
  const StorageScreen({super.key});

  @override
  ConsumerState<StorageScreen> createState() => _StorageScreenState();
}

class _StorageScreenState extends ConsumerState<StorageScreen> {
  late Future<StorageUsage> _usage = ref.read(storageServiceProvider).usage();

  void _reload() => setState(() => _usage = ref.read(storageServiceProvider).usage());

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Storage')),
      body: FutureBuilder<StorageUsage>(
        future: _usage,
        builder: (context, snap) {
          final u = snap.data;
          if (u == null) return const Center(child: CircularProgressIndicator());
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    children: [
                      Text('App storage', style: TextStyle(color: context.mutedColor)),
                      const SizedBox(height: 4),
                      Text(
                        Formatters.fileSize(u.totalBytes),
                        style: Theme.of(context).textTheme.headlineMedium
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              _row(Icons.file_download_outlined, 'Exported videos', u.exportsBytes),
              _row(Icons.video_library_outlined, 'Imported media (used by projects)', u.mediaBytes),
              _row(Icons.description_outlined, 'Project data', u.projectDataBytes),
              _row(Icons.photo_outlined, 'Thumbnail cache', u.cacheBytes),
              _row(Icons.hourglass_empty, 'Temporary files', u.tempBytes),
              const SizedBox(height: 20),
              FilledButton.icon(
                icon: const Icon(Icons.cleaning_services_outlined),
                label: const Text('Clear Temporary Files'),
                onPressed: () async {
                  await ref.read(storageServiceProvider).clearTemporaryFiles();
                  // Also drop imported media no project uses any more.
                  await CollectUnusedMedia(
                    ref.read(projectRepositoryProvider),
                    ref.read(mediaRepositoryProvider),
                  )();
                  if (!context.mounted) return;
                  showSnack(context, 'Temporary files cleared');
                  _reload();
                },
              ),
              const SizedBox(height: 8),
              Text(
                'Clears processing leftovers, the thumbnail cache and media that no project '
                'uses. Your projects and exported videos are not affected.',
                style: TextStyle(fontSize: 12, color: context.mutedColor),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _row(IconData icon, String label, int bytes) =>
      ListTile(leading: Icon(icon), title: Text(label), trailing: Text(Formatters.fileSize(bytes)));
}
