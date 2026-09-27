import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/theme/app_theme.dart';
import '../../domain/entities/logo_placement.dart';
import '../../services/picker/media_picker.dart';
import 'app_dialogs.dart';
import 'media_import_flow.dart';

/// "Your logos" strip: pick a saved logo, add a new one (PNG transparency
/// is kept), long-press to delete. Reports the chosen relative path.
class LogoPicker extends ConsumerStatefulWidget {
  const LogoPicker({super.key, required this.selected, required this.onSelected});

  final String? selected;
  final ValueChanged<String> onSelected;

  @override
  ConsumerState<LogoPicker> createState() => _LogoPickerState();
}

class _LogoPickerState extends ConsumerState<LogoPicker> {
  List<String> _logos = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final logos = await ref.read(mediaRepositoryProvider).listLogos();
    if (mounted) setState(() => _logos = logos);
  }

  Future<void> _add() async {
    final source = await showModalBottomSheet<PickSource>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Gallery'),
              onTap: () => Navigator.pop(context, PickSource.gallery),
            ),
            ListTile(
              leading: const Icon(Icons.folder_open_outlined),
              title: const Text('Files'),
              subtitle: const Text('PNG with a transparent background works best'),
              onTap: () => Navigator.pop(context, PickSource.files),
            ),
          ],
        ),
      ),
    );
    if (source == null || !mounted) return;
    try {
      final picked = await ref.read(mediaPickerProvider).pickImages(source);
      if (picked.isEmpty || !mounted) return;
      final path = await ref.read(mediaRepositoryProvider).importLogo(picked.first);
      await _load();
      widget.onSelected(path);
    } catch (e) {
      if (mounted) await showAppError(context, e);
    }
  }

  Future<void> _delete(String path) async {
    final ok = await confirm(
      context,
      title: 'Delete logo?',
      message:
          'It will be removed from your logos. Videos already using it keep it until '
          'you re-edit them.',
    );
    if (!ok) return;
    await ref.read(mediaRepositoryProvider).deleteLogo(path);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final media = ref.read(mediaRepositoryProvider);
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: 72,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          _Tile(
            onTap: _add,
            color: scheme.surfaceContainerHighest,
            child: const Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.add_photo_alternate_outlined),
                Text('Add logo', style: TextStyle(fontSize: 10)),
              ],
            ),
          ),
          for (final logo in _logos)
            _Tile(
              onTap: () => widget.onSelected(logo),
              onLongPress: () => _delete(logo),
              selected: widget.selected == logo,
              // Checkerboard-ish backdrop so transparent logos stay visible.
              color: const Color(0xFF3A3F4B),
              child: Padding(
                padding: const EdgeInsets.all(6),
                child: Image.file(File(media.resolve(logo)), fit: BoxFit.contain, cacheWidth: 200),
              ),
            ),
        ],
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({
    required this.onTap,
    required this.child,
    required this.color,
    this.onLongPress,
    this.selected = false,
  });

  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final Widget child;
  final Color color;
  final bool selected;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(right: 8),
    child: InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        width: 72,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: selected ? AppColors.selection : Colors.transparent, width: 2),
        ),
        child: child,
      ),
    ),
  );
}

/// Corner/centre quick-position chips.
class LogoPositionChips extends StatelessWidget {
  const LogoPositionChips({super.key, required this.onSelected, this.selected});
  final LogoPosition? selected;
  final ValueChanged<LogoPosition> onSelected;

  static IconData _icon(LogoPosition p) => switch (p) {
    LogoPosition.topLeft => Icons.north_west,
    LogoPosition.topRight => Icons.north_east,
    LogoPosition.bottomLeft => Icons.south_west,
    LogoPosition.bottomRight => Icons.south_east,
    LogoPosition.center => Icons.filter_center_focus,
  };

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 6,
    runSpacing: 6,
    children: [
      for (final p in LogoPosition.values)
        ChoiceChip(
          avatar: Icon(_icon(p), size: 16),
          label: Text(p.label),
          selected: selected == p,
          onSelected: (_) => onSelected(p),
        ),
    ],
  );
}
