import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../../app/providers.dart';
import '../../core/utils/formatters.dart';
import '../../domain/entities/project.dart';
import '../../domain/entities/project_timeline.dart';
import '../editor/editor_screen.dart';
import '../widgets/app_dialogs.dart';

/// Continue / rename / duplicate / delete for a project.
class ProjectActions {
  const ProjectActions(this.ref);
  final WidgetRef ref;

  Future<void> open(BuildContext context, Project project) async {
    // Re-read from disk so the editor starts from the latest save.
    final fresh = await ref.read(projectRepositoryProvider).getById(project.id) ?? project;
    if (!context.mounted) return;
    await EditorScreen.open(context, fresh);
    await ref.read(projectsProvider.notifier).refresh();
  }

  Future<void> rename(BuildContext context, Project project) async {
    final name = await promptText(context, title: 'Rename project', initial: project.name);
    if (name != null && name.trim().isNotEmpty) {
      await ref.read(projectsProvider.notifier).rename(project.id, name);
    }
  }

  Future<void> duplicate(BuildContext context, Project project) async {
    await ref.read(projectsProvider.notifier).duplicate(project.id);
    if (context.mounted) showSnack(context, 'Project duplicated');
  }

  Future<void> delete(BuildContext context, Project project) async {
    final ok = await confirm(
      context,
      title: 'Delete project?',
      message: '"${project.name}" will be deleted. Exported videos are kept.',
    );
    if (ok) await ref.read(projectsProvider.notifier).delete(project.id);
  }

  Future<void> showMenu(BuildContext context, Project project) => showModalBottomSheet<void>(
    context: context,
    builder: (sheet) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.edit_note),
            title: const Text('Continue editing'),
            onTap: () {
              Navigator.pop(sheet);
              open(context, project);
            },
          ),
          ListTile(
            leading: const Icon(Icons.drive_file_rename_outline),
            title: const Text('Rename'),
            onTap: () {
              Navigator.pop(sheet);
              rename(context, project);
            },
          ),
          ListTile(
            leading: const Icon(Icons.copy_all_outlined),
            title: const Text('Duplicate'),
            onTap: () {
              Navigator.pop(sheet);
              duplicate(context, project);
            },
          ),
          ListTile(
            leading: Icon(Icons.delete_outline, color: Theme.of(context).colorScheme.error),
            title: Text('Delete', style: TextStyle(color: Theme.of(context).colorScheme.error)),
            onTap: () {
              Navigator.pop(sheet);
              delete(context, project);
            },
          ),
        ],
      ),
    ),
  );
}

class ProjectCard extends ConsumerWidget {
  const ProjectCard({super.key, required this.project, this.width});
  final Project project;
  final double? width;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final paths = ref.read(appPathsProvider);
    final cover = project.coverPath == null ? null : File(paths.toAbsolute(project.coverPath!));
    final actions = ProjectActions(ref);
    final duration = ProjectTimeline(project).duration;

    return SizedBox(
      width: width,
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => actions.open(context, project),
          onLongPress: () => actions.showMenu(context, project),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AspectRatio(
                aspectRatio: 16 / 10,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (cover != null && cover.existsSync())
                      Image.file(cover, fit: BoxFit.cover, cacheWidth: 480)
                    else
                      const ColoredBox(
                        color: Color(0xFF232838),
                        child: Icon(Icons.movie_outlined, size: 36, color: Colors.white30),
                      ),
                    Positioned(
                      right: 6,
                      bottom: 6,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          Formatters.duration(duration),
                          style: const TextStyle(fontSize: 11, color: Colors.white),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 0, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            project.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'Edited ${Formatters.relativeTime(project.updatedAt)}',
                            style: TextStyle(fontSize: 11, color: context.mutedColor),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.more_vert, size: 20),
                      onPressed: () => actions.showMenu(context, project),
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
