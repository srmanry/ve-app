import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/constants/app_constants.dart';
import '../../core/theme/app_theme.dart';
import '../editor/state/editor_state.dart';
import '../exports/exported_media_tile.dart';
import '../projects/project_card.dart';
import 'create_flows.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({
    super.key,
    required this.onSeeAllProjects,
    required this.onSeeAllExports,
  });

  final VoidCallback onSeeAllProjects;
  final VoidCallback onSeeAllExports;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final flows = CreateFlows(ref);
    final projects = ref.watch(projectsProvider).value ?? const [];
    final exports = ref.watch(exportsProvider).value ?? const [];

    final tools = <_Tool>[
      _Tool(Icons.videocam_outlined, 'Camera', () => flows.record(context)),
      _Tool(
        Icons.edit_outlined,
        'Edit Video',
        () => flows.createProject(context),
      ),
      _Tool(
        Icons.content_cut_outlined,
        'Trim Video',
        () => flows.createProject(
          context,
          tool: EditorTool.trim,
          multiple: false,
          allowPhotos: false,
        ),
      ),
      _Tool(
        Icons.slideshow_outlined,
        'Photo Slideshow',
        () => flows.slideshow(context),
      ),
      _Tool(
        Icons.merge_type_outlined,
        'Merge Videos',
        () => flows.merge(context),
      ),
      _Tool(
        Icons.audiotrack_outlined,
        'Video to Audio',
        () => flows.videoToAudio(context),
      ),
      _Tool(Icons.compress_outlined, 'Compress', () => flows.compress(context)),
      _Tool(Icons.movie_edit, 'Cut Video', () => flows.cut(context)),
      _Tool(Icons.auto_awesome_outlined, 'Themes', () => flows.themes(context)),
      _Tool(
        Icons.person_remove_outlined,
        'Remove Background',
        () => flows.createProject(
          context,
          tool: EditorTool.removeBackground,
          multiple: false,
        ),
      ),
      _Tool(
        Icons.auto_fix_high_outlined,
        'Video Effects',
        () => flows.createProject(context, tool: EditorTool.effects),
      ),
      _Tool(
        Icons.graphic_eq_outlined,
        'Remove Noise',
        () => flows.createProject(
          context,
          tool: EditorTool.denoise,
          multiple: false,
          allowPhotos: false,
        ),
      ),
    ];

    return Scaffold(
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: () async {
            await ref.read(projectsProvider.notifier).refresh();
            await ref.read(exportsProvider.notifier).refresh();
          },
          child: ListView(
            padding: const EdgeInsets.fromLTRB(18, 14, 18, 28),
            children: [
              const _Header(),
              const SizedBox(height: 22),
              _ToolPanel(
                title: 'Quick actions',
                badge: 'On-device',
                tools: tools,
                columns: 4,
              ),
              const SizedBox(height: 22),
              _HeroCard(
                onImport: () => flows.createProject(context),
                onCamera: () => flows.record(context),
              ),
              const SizedBox(height: 28),
              _SectionTitle(
                title: 'Recent projects',
                onSeeAll: projects.isEmpty ? null : onSeeAllProjects,
              ),
              const SizedBox(height: 12),
              if (projects.isEmpty)
                _EmptyCard(
                  icon: Icons.video_library_rounded,
                  title: 'No projects yet',
                  message: 'Your drafts are saved here automatically.',
                  actionLabel: 'Start',
                  onAction: () => flows.createProject(context),
                )
              else
                SizedBox(
                  height: 190,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: projects.length.clamp(0, 10),
                    separatorBuilder: (_, _) => const SizedBox(width: 12),
                    itemBuilder: (context, i) =>
                        ProjectCard(project: projects[i], width: 190),
                  ),
                ),
              const SizedBox(height: 28),
              _SectionTitle(
                title: 'Recent exports',
                onSeeAll: exports.isEmpty ? null : onSeeAllExports,
              ),
              const SizedBox(height: 8),
              if (exports.isEmpty)
                const _EmptyCard(
                  icon: Icons.download_done_rounded,
                  title: 'Nothing exported yet',
                  message: 'Finished videos show up here, ready to share.',
                )
              else
                for (final e in exports.take(3)) ExportedMediaTile(media: e),
            ],
          ),
        ),
      ),
    );
  }
}

// --------------------------------------------------------------------- header

class _Header extends StatelessWidget {
  const _Header();

  String get _greeting {
    final h = DateTime.now().hour;
    if (h < 12) return 'Good morning';
    if (h < 17) return 'Good afternoon';
    return 'Good evening';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Container(
          width: 46,
          height: 46,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [scheme.primary, scheme.secondary],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(14),
            boxShadow: [
              BoxShadow(
                color: scheme.primary.withValues(alpha: 0.35),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: const Icon(Icons.movie_filter_rounded, color: Colors.white),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _greeting,
                style: TextStyle(fontSize: 12.5, color: context.mutedColor),
              ),
              Text(
                AppConstants.appName,
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.3,
                ),
              ),
            ],
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: const Color(0xFF10B981).withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(20),
          ),
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.shield_rounded, size: 14, color: Color(0xFF10B981)),
              SizedBox(width: 4),
              Text(
                'Private',
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF10B981),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ----------------------------------------------------------------------- hero

/// Compact "new project" bar: tap to import, camera button to record.
class _HeroCard extends StatelessWidget {
  const _HeroCard({required this.onImport, required this.onCamera});
  final VoidCallback onImport;
  final VoidCallback onCamera;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [AppColors.accent, AppColors.accentAlt],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withValues(alpha: 0.22)),
        boxShadow: [
          BoxShadow(
            color: scheme.primary.withValues(alpha: 0.24),
            blurRadius: 18,
            offset: const Offset(0, 7),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(20),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onImport,
          splashColor: Colors.white.withValues(alpha: 0.12),
          highlightColor: Colors.white.withValues(alpha: 0.06),
          child: Stack(
            children: [
              Positioned(
                right: -24,
                top: -34,
                child: Container(
                  width: 96,
                  height: 96,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.08),
                    shape: BoxShape.circle,
                  ),
                ),
              ),
              Positioned(
                right: 58,
                bottom: -46,
                child: Container(
                  width: 78,
                  height: 78,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.055),
                    shape: BoxShape.circle,
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(13, 12, 11, 12),
                child: Row(
                  children: [
                    SizedBox(
                      width: 48,
                      height: 48,
                      child: Stack(
                        children: [
                          Container(
                            width: 46,
                            height: 46,
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(15),
                            ),
                            child: Icon(
                              Icons.movie_filter_outlined,
                              color: scheme.primary,
                              size: 24,
                            ),
                          ),
                          Positioned(
                            right: 0,
                            bottom: 0,
                            child: Container(
                              width: 19,
                              height: 19,
                              decoration: BoxDecoration(
                                color: scheme.primary,
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: Colors.white,
                                  width: 2,
                                ),
                              ),
                              child: const Icon(
                                Icons.add_rounded,
                                color: Colors.white,
                                size: 12,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            'Create New Video',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                              letterSpacing: -0.2,
                            ),
                          ),
                          SizedBox(height: 1),
                          Text(
                            'Import videos or photos',
                            style: TextStyle(
                              color: Colors.white70,
                              fontSize: 11.5,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Tooltip(
                      message: 'Record with camera',
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.18),
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.24),
                          ),
                        ),
                        child: Material(
                          color: Colors.transparent,
                          shape: const CircleBorder(),
                          clipBehavior: Clip.antiAlias,
                          child: InkWell(
                            customBorder: const CircleBorder(),
                            onTap: onCamera,
                            child: const Padding(
                              padding: EdgeInsets.all(11),
                              child: Icon(
                                Icons.videocam_outlined,
                                color: Colors.white,
                                size: 21,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- section title

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.title, this.onSeeAll});
  final String title;
  final VoidCallback? onSeeAll;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: Text(
          title,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w800,
            fontSize: 17,
            letterSpacing: -0.2,
          ),
        ),
      ),
      if (onSeeAll != null)
        TextButton(
          onPressed: onSeeAll,
          style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('See all'),
              SizedBox(width: 2),
              Icon(Icons.chevron_right_rounded, size: 18),
            ],
          ),
        ),
    ],
  );
}

// ---------------------------------------------------------------- quick tools

class _Tool {
  const _Tool(this.icon, this.label, this.onTap);
  final IconData icon;
  final String label;
  final VoidCallback onTap;
}

/// A compact grid with the icon tile above its label.
class _ToolPanel extends StatelessWidget {
  const _ToolPanel({
    required this.title,
    required this.tools,
    required this.columns,
    this.badge,
  });

  final String title;
  final List<_Tool> tools;
  final int columns;
  final String? badge;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              title,
              style: const TextStyle(
                fontSize: 16.5,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.25,
              ),
            ),
            const Spacer(),
            if (badge != null)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: scheme.primary.withValues(alpha: 0.09),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.lock_outline_rounded,
                      size: 11,
                      color: scheme.primary,
                    ),
                    const SizedBox(width: 3),
                    Text(
                      badge!,
                      style: TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w600,
                        color: scheme.primary,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
        const SizedBox(height: 12),
        LayoutBuilder(
          builder: (context, box) {
            const spacing = 9.0;
            final cellWidth =
                (box.maxWidth - spacing * (columns - 1)) / columns;
            const cellHeight = 80.0;
            return Wrap(
              spacing: spacing,
              runSpacing: 14,
              children: [
                for (final tool in tools)
                  SizedBox(
                    width: cellWidth,
                    height: cellHeight,
                    child: _ToolTile(tool: tool),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }
}

/// Soft accent squircle with an outline icon, label underneath.
class _ToolTile extends StatelessWidget {
  const _ToolTile({required this.tool});
  final _Tool tool;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: tool.onTap,
        splashColor: scheme.primary.withValues(alpha: 0.10),
        highlightColor: scheme.primary.withValues(alpha: 0.04),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(
              width: 44,
              height: 44,
              child: Icon(tool.icon, size: 24, color: scheme.primary),
            ),
            const SizedBox(height: 5),
            SizedBox(
              height: 29,
              child: Text(
                tool.label,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 10.5,
                  height: 1.2,
                  fontWeight: FontWeight.w500,
                  color: scheme.onSurface,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- empty state

class _EmptyCard extends StatelessWidget {
  const _EmptyCard({
    required this.icon,
    required this.title,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: dark
            ? scheme.surfaceContainerHigh
            : scheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.6)),
      ),
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: scheme.primary.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(15),
            ),
            child: Icon(icon, color: scheme.primary),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 2),
                Text(
                  message,
                  style: TextStyle(fontSize: 12.5, color: context.mutedColor),
                ),
              ],
            ),
          ),
          if (actionLabel != null && onAction != null) ...[
            const SizedBox(width: 8),
            FilledButton.tonal(
              onPressed: onAction,
              style: FilledButton.styleFrom(
                minimumSize: const Size(0, 36),
                padding: const EdgeInsets.symmetric(horizontal: 14),
                textStyle: const TextStyle(
                  fontFamily: 'Poppins',
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
              child: Text(actionLabel!),
            ),
          ],
        ],
      ),
    );
  }
}
