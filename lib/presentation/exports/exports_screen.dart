import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../widgets/empty_state.dart';
import 'exported_media_tile.dart';

class ExportsScreen extends ConsumerWidget {
  const ExportsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final exports = ref.watch(exportsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Exported videos')),
      body: exports.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, _) => const EmptyState(
          icon: Icons.error_outline,
          title: 'Couldn\'t load exports',
          message: 'Please restart the app.',
        ),
        data: (list) => list.isEmpty
            ? const EmptyState(
                icon: Icons.file_download_outlined,
                title: 'No exports yet',
                message: 'Videos you export are listed here.',
              )
            : RefreshIndicator(
                onRefresh: ref.read(exportsProvider.notifier).refresh,
                child: ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: list.length,
                  itemBuilder: (context, i) => ExportedMediaTile(media: list[i]),
                ),
              ),
      ),
    );
  }
}
