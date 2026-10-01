import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../domain/entities/exported_media.dart';
import '../widgets/empty_state.dart';
import 'exported_media_tile.dart';

/// Tabs of the Exports screen.
enum ExportKind {
  all('All', Icons.folder_outlined),
  video('Video', Icons.movie_outlined),
  audio('Audio', Icons.music_note_outlined),
  image('Image', Icons.image_outlined);

  const ExportKind(this.label, this.icon);
  final String label;
  final IconData icon;

  bool matches(ExportedMedia m) => switch (this) {
    ExportKind.all => true,
    ExportKind.video => !m.isAudioOnly && !m.isImage && !m.isDocument,
    ExportKind.audio => m.isAudioOnly,
    ExportKind.image => m.isImage || m.isDocument,
  };
}

class ExportsScreen extends ConsumerStatefulWidget {
  const ExportsScreen({super.key});

  @override
  ConsumerState<ExportsScreen> createState() => _ExportsScreenState();
}

class _ExportsScreenState extends ConsumerState<ExportsScreen> with SingleTickerProviderStateMixin {
  final _search = TextEditingController();
  late final _tabs = TabController(length: ExportKind.values.length, vsync: this)
    ..addListener(() {
      if (mounted) setState(() {});
    });
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final exports = ref.watch(exportsProvider);
    final list = exports.value ?? const <ExportedMedia>[];
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Exports'),
        bottom: list.isEmpty
            ? null
            : TabBar(
                controller: _tabs,
                isScrollable: false,
                indicatorSize: TabBarIndicatorSize.label,
                labelStyle: const TextStyle(fontFamily: 'Poppins', fontWeight: FontWeight.w600, fontSize: 13),
                unselectedLabelStyle: const TextStyle(fontFamily: 'Poppins', fontWeight: FontWeight.w500, fontSize: 13),
                labelColor: scheme.primary,
                dividerColor: scheme.outlineVariant.withValues(alpha: 0.4),
                tabs: [
                  for (final k in ExportKind.values)
                    Tab(
                      height: 42,
                      child: Text('${k.label} ${list.where(k.matches).length}'),
                    ),
                ],
              ),
      ),
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
                message: 'Videos, audio and photos you save are listed here.',
              )
            : _ExportList(
                list: list,
                kind: ExportKind.values[_tabs.index],
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
    required this.kind,
    required this.controller,
    required this.query,
    required this.onQueryChanged,
    required this.onClear,
    required this.onRefresh,
  });

  final List<ExportedMedia> list;
  final ExportKind kind;
  final TextEditingController controller;
  final String query;
  final ValueChanged<String> onQueryChanged;
  final VoidCallback onClear;
  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context) {
    final normalized = query.trim().toLowerCase();
    final filtered = list
        .where(kind.matches)
        .where((media) => normalized.isEmpty || media.fileName.toLowerCase().contains(normalized))
        .toList(growable: false);

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
          child: TextField(
            controller: controller,
            onChanged: onQueryChanged,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              hintText: switch (kind) {
                ExportKind.all => 'Search videos, audio and photos',
                ExportKind.video => 'Search videos',
                ExportKind.audio => 'Search audio',
                ExportKind.image => 'Search photos and PDFs',
              },
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
              ? normalized.isNotEmpty
                    ? const EmptyState(
                        icon: Icons.search_off_rounded,
                        title: 'No matching exports',
                        message: 'Try a different file name.',
                      )
                    : EmptyState(
                        icon: kind.icon,
                        title: switch (kind) {
                          ExportKind.video => 'No videos yet',
                          ExportKind.audio => 'No audio yet',
                          ExportKind.image => 'No photos yet',
                          ExportKind.all => 'No exports yet',
                        },
                        message: switch (kind) {
                          ExportKind.video => 'Videos you export show up here.',
                          ExportKind.audio => 'Files from the audio tools show up here.',
                          ExportKind.image => 'Photos from the image tools show up here.',
                          ExportKind.all => 'Videos, audio and photos you save are listed here.',
                        },
                      )
              : RefreshIndicator(
                  onRefresh: onRefresh,
                  child: ListView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                    itemCount: filtered.length,
                    itemBuilder: (context, i) => ExportedMediaTile(media: filtered[i]),
                  ),
                ),
        ),
      ],
    );
  }
}
