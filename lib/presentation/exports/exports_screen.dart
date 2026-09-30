import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../domain/entities/exported_media.dart';
import '../widgets/empty_state.dart';
import 'exported_media_tile.dart';

class ExportsScreen extends ConsumerStatefulWidget {
  const ExportsScreen({super.key});

  @override
  ConsumerState<ExportsScreen> createState() => _ExportsScreenState();
}

class _ExportsScreenState extends ConsumerState<ExportsScreen> {
  final _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
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
            : _ExportList(
                list: list,
                controller: _search,
                query: _query,
                onQueryChanged: (value) => setState(() => _query = value),
                onClear: () {
                  _search.clear();
                  setState(() => _query = '');
                },
                onRefresh: ref.read(exportsProvider.notifier).refresh,
              ),
      ),
    );
  }
}

class _ExportList extends StatelessWidget {
  const _ExportList({
    required this.list,
    required this.controller,
    required this.query,
    required this.onQueryChanged,
    required this.onClear,
    required this.onRefresh,
  });

  final List<ExportedMedia> list;
  final TextEditingController controller;
  final String query;
  final ValueChanged<String> onQueryChanged;
  final VoidCallback onClear;
  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context) {
    final normalized = query.trim().toLowerCase();
    final filtered = normalized.isEmpty
        ? list
        : list
              .where(
                (media) => media.fileName.toLowerCase().contains(normalized),
              )
              .toList(growable: false);

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: TextField(
            controller: controller,
            onChanged: onQueryChanged,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              hintText: 'Search exported videos and audio',
              prefixIcon: const Icon(Icons.search_rounded),
              suffixIcon: query.isEmpty
                  ? null
                  : IconButton(
                      tooltip: 'Clear search',
                      onPressed: onClear,
                      icon: const Icon(Icons.close_rounded),
                    ),
              filled: true,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide.none,
              ),
              contentPadding: const EdgeInsets.symmetric(vertical: 12),
            ),
          ),
        ),
        Expanded(
          child: filtered.isEmpty
              ? const EmptyState(
                  icon: Icons.search_off_rounded,
                  title: 'No matching exports',
                  message: 'Try a different file name.',
                )
              : RefreshIndicator(
                  onRefresh: onRefresh,
                  child: ListView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    keyboardDismissBehavior:
                        ScrollViewKeyboardDismissBehavior.onDrag,
                    itemCount: filtered.length,
                    itemBuilder: (context, i) =>
                        ExportedMediaTile(media: filtered[i]),
                  ),
                ),
        ),
      ],
    );
  }
}
