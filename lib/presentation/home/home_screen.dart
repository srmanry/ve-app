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
  const HomeScreen({super.key, required this.onSeeAllProjects, required this.onSeeAllExports});

  final VoidCallback onSeeAllProjects;
  final VoidCallback onSeeAllExports;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final flows = CreateFlows(ref);
    final projects = ref.watch(projectsProvider).value ?? const [];
    final exports = ref.watch(exportsProvider).value ?? const [];

    return Scaffold(
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: () async {
            await ref.read(projectsProvider.notifier).refresh();
            await ref.read(exportsProvider.notifier).refresh();
          },
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            children: [
              const _Header(),
              const SizedBox(height: 20),
              _CreateButton(onTap: () => flows.createProject(context)),
              const SizedBox(height: 24),
              const _ActionSectionHeader(
                icon: Icons.grid_view_rounded,
                title: 'Quick actions',
                badge: '9 tools',
              ),
              const SizedBox(height: 12),
              _QuickActions(
                actions: [
                  _QuickAction(Icons.videocam_outlined, 'Camera', () => flows.record(context)),
                  _QuickAction(
                    Icons.edit_outlined,
                    'Edit Video',
                    () => flows.createProject(context),
                  ),
                  _QuickAction(
                    Icons.content_cut,
                    'Trim Video',
                    () => flows.createProject(
                      context,
                      tool: EditorTool.trim,
                      multiple: false,
                      allowPhotos: false,
                    ),
                  ),
                  _QuickAction(
                    Icons.slideshow_outlined,
                    'Photo Slideshow',
                    () => flows.slideshow(context),
                  ),
                  _QuickAction(Icons.merge_type, 'Merge Videos', () => flows.merge(context)),
                  _QuickAction(
                    Icons.audiotrack_outlined,
                    'Video to Audio',
                    () => flows.videoToAudio(context),
                  ),
                  _QuickAction(Icons.compress, 'Compress Video', () => flows.compress(context)),
                  _QuickAction(Icons.movie_edit, 'Cut Video', () => flows.cut(context)),
                  _QuickAction(Icons.auto_awesome, 'Themes', () => flows.themes(context)),
                ],
              ),
              const SizedBox(height: 24),
              const _ActionSectionHeader(
                icon: Icons.auto_awesome_rounded,
                title: 'AI & Effects',
                badge: 'On-device',
                badgeIcon: Icons.lock_outline_rounded,
              ),
              const SizedBox(height: 12),
              _QuickActions(
                actions: [
                  _QuickAction(
                    Icons.person_remove_outlined,
                    'Remove Background',
                    () => flows.createProject(
                      context,
                      tool: EditorTool.removeBackground,
                      multiple: false,
                    ),
                  ),
                  _QuickAction(
                    Icons.auto_fix_high,
                    'Video Effects',
                    () => flows.createProject(context, tool: EditorTool.effects),
                  ),
                  _QuickAction(
                    Icons.noise_control_off,
                    'Remove Noise',
                    () => flows.createProject(
                      context,
                      tool: EditorTool.denoise,
                      multiple: false,
                      allowPhotos: false,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              _SectionHeader(
                title: 'Recent projects',
                onSeeAll: projects.isEmpty ? null : onSeeAllProjects,
              ),
              const SizedBox(height: 10),
              if (projects.isEmpty)
                const _EmptyHint('Your projects will appear here.')
              else
                SizedBox(
                  height: 190,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: projects.length.clamp(0, 10),
                    separatorBuilder: (_, _) => const SizedBox(width: 12),
                    itemBuilder: (context, i) => ProjectCard(project: projects[i], width: 190),
                  ),
                ),
              const SizedBox(height: 24),
              _SectionHeader(
                title: 'Recent exports',
                onSeeAll: exports.isEmpty ? null : onSeeAllExports,
              ),
              const SizedBox(height: 6),
              if (exports.isEmpty)
                const _EmptyHint('Exported videos will appear here.')
              else
                for (final e in exports.take(3)) ExportedMediaTile(media: e),
            ],
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header();

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          gradient: const LinearGradient(colors: [AppColors.accent, AppColors.accentAlt]),
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Icon(Icons.movie_filter_rounded, color: Colors.white),
      ),
      const SizedBox(width: 12),
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            AppConstants.appName,
            style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
          ),
          Row(
            children: [
              Icon(Icons.lock_outline, size: 12, color: context.mutedColor),
              const SizedBox(width: 4),
              Text(
                '100% offline · private',
                style: TextStyle(fontSize: 12, color: context.mutedColor),
              ),
            ],
          ),
        ],
      ),
    ],
  );
}

class _CreateButton extends StatelessWidget {
  const _CreateButton({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
    borderRadius: BorderRadius.circular(20),
    clipBehavior: Clip.antiAlias,
    child: Ink(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [AppColors.accent, AppColors.accentAlt],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: InkWell(
        onTap: onTap,
        child: const Padding(
          padding: EdgeInsets.symmetric(vertical: 26, horizontal: 20),
          child: Row(
            children: [
              CircleAvatar(
                radius: 24,
                backgroundColor: Colors.white24,
                child: Icon(Icons.add, color: Colors.white, size: 28),
              ),
              SizedBox(width: 16),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Create New Video',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                    ),
                  ),
                  SizedBox(height: 2),
                  Text(
                    'Import from gallery or files',
                    style: TextStyle(fontSize: 13, color: Colors.white70),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _QuickAction {
  const _QuickAction(this.icon, this.label, this.onTap);
  final IconData icon;
  final String label;
  final VoidCallback onTap;
}

class _QuickActions extends StatelessWidget {
  const _QuickActions({required this.actions});
  final List<_QuickAction> actions;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final scheme = Theme.of(context).colorScheme;
      final dark = Theme.of(context).brightness == Brightness.dark;
      final perRow = box.maxWidth > 500 ? 6 : 3;
      final width = (box.maxWidth - (perRow - 1) * 10) / perRow;
      return Wrap(
        spacing: 10,
        runSpacing: 10,
        children: [
          for (final a in actions)
            SizedBox(
              width: width,
              height: 108,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      scheme.surface,
                      Color.alphaBlend(
                        scheme.primary.withValues(alpha: dark ? 0.07 : 0.035),
                        scheme.surface,
                      ),
                    ],
                  ),
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(
                    color: Color.alphaBlend(
                      scheme.primary.withValues(alpha: dark ? 0.16 : 0.10),
                      scheme.outlineVariant,
                    ),
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: scheme.shadow.withValues(alpha: dark ? 0.12 : 0.06),
                      blurRadius: 14,
                      offset: const Offset(0, 5),
                    ),
                  ],
                ),
                child: InkWell(
                  borderRadius: BorderRadius.circular(18),
                  onTap: a.onTap,
                  splashColor: scheme.primary.withValues(alpha: 0.10),
                  highlightColor: scheme.primary.withValues(alpha: 0.05),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 13, horizontal: 7),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            gradient: const LinearGradient(
                              colors: [AppColors.accent, AppColors.accentAlt],
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                            ),
                            borderRadius: BorderRadius.circular(13),
                            boxShadow: [
                              BoxShadow(
                                color: AppColors.accent.withValues(alpha: 0.22),
                                blurRadius: 9,
                                offset: const Offset(0, 4),
                              ),
                            ],
                          ),
                          child: Icon(a.icon, color: Colors.white, size: 21),
                        ),
                        const SizedBox(height: 9),
                        Text(
                          a.label,
                          textAlign: TextAlign.center,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 11,
                            height: 1.18,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      );
    },
  );
}

class _ActionSectionHeader extends StatelessWidget {
  const _ActionSectionHeader({
    required this.icon,
    required this.title,
    required this.badge,
    this.badgeIcon,
  });

  final IconData icon;
  final String title;
  final String badge;
  final IconData? badgeIcon;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            color: scheme.primary.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(11),
          ),
          child: Icon(icon, size: 18, color: scheme.primary),
        ),
        const SizedBox(width: 10),
        Text(title, style: Theme.of(context).textTheme.titleMedium),
        const Spacer(),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
          decoration: BoxDecoration(
            color: scheme.surface,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: scheme.outlineVariant),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (badgeIcon != null) ...[
                Icon(badgeIcon, size: 12, color: scheme.primary),
                const SizedBox(width: 4),
              ],
              Text(
                badge,
                style: TextStyle(
                  color: context.mutedColor,
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, this.onSeeAll});
  final String title;
  final VoidCallback? onSeeAll;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Text(title, style: Theme.of(context).textTheme.titleMedium),
      const Spacer(),
      if (onSeeAll != null) TextButton(onPressed: onSeeAll, child: const Text('See all')),
    ],
  );
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(20),
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
    ),
    child: Text(
      text,
      textAlign: TextAlign.center,
      style: TextStyle(color: context.mutedColor),
    ),
  );
}
