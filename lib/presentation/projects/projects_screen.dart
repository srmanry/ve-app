import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../home/create_flows.dart';
import '../widgets/empty_state.dart';
import 'project_card.dart';

class ProjectsScreen extends ConsumerWidget {
  const ProjectsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final projects = ref.watch(projectsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Projects')),
      body: projects.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => const EmptyState(
          icon: Icons.error_outline,
          title: 'Couldn\'t load projects',
          message: 'Please restart the app.',
        ),
        data: (list) => list.isEmpty
            ? EmptyState(
                icon: Icons.video_library_outlined,
                title: 'No projects yet',
                message: 'Projects are saved automatically on this device.',
                action: FilledButton.icon(
                  onPressed: () => CreateFlows(ref).createProject(context),
                  icon: const Icon(Icons.add),
                  label: const Text('Create new video'),
                ),
              )
            : RefreshIndicator(
                onRefresh: ref.read(projectsProvider.notifier).refresh,
                child: LayoutBuilder(
                  builder: (context, box) => GridView.builder(
                    padding: const EdgeInsets.all(16),
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: box.maxWidth > 600 ? 3 : 2,
                      mainAxisSpacing: 12,
                      crossAxisSpacing: 12,
                      childAspectRatio: 0.92,
                    ),
                    itemCount: list.length,
                    itemBuilder: (context, i) => ProjectCard(project: list[i]),
                  ),
                ),
              ),
      ),
    );
  }
}
