import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../exports/exports_screen.dart';
import '../home/create_flows.dart';
import '../home/home_screen.dart';
import '../projects/projects_screen.dart';
import '../settings/settings_screen.dart';

/// Bottom navigation: Home · Projects · Create · Exports · Settings.
/// "Create" starts the import → editor flow instead of switching tab.
class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key});

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  int _tab = 0;

  static const _createIndex = 2;

  void _select(int index) {
    if (index == _createIndex) {
      CreateFlows(ref).createProject(context);
      return;
    }
    setState(() => _tab = index);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final pages = [
      HomeScreen(onSeeAllProjects: () => _select(1), onSeeAllExports: () => _select(3)),
      const ProjectsScreen(),
      const SizedBox.shrink(),
      const ExportsScreen(),
      const SettingsScreen(),
    ];
    return Scaffold(
      body: IndexedStack(index: _tab, children: pages),
      bottomNavigationBar: SafeArea(
        minimum: const EdgeInsets.fromLTRB(12, 0, 12, 10),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: scheme.surface,
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: scheme.outlineVariant),
            boxShadow: [
              BoxShadow(
                color: scheme.shadow.withValues(alpha: 0.10),
                blurRadius: 22,
                offset: const Offset(0, 7),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(22),
            child: NavigationBar(
              backgroundColor: Colors.transparent,
              surfaceTintColor: Colors.transparent,
              elevation: 0,
              selectedIndex: _tab,
              onDestinationSelected: _select,
              labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
              destinations: [
                const NavigationDestination(
                  icon: Icon(Icons.home_outlined),
                  selectedIcon: Icon(Icons.home),
                  label: 'Home',
                ),
                const NavigationDestination(
                  icon: Icon(Icons.video_library_outlined),
                  selectedIcon: Icon(Icons.video_library),
                  label: 'Projects',
                ),
                NavigationDestination(
                  icon: Container(
                    padding: const EdgeInsets.all(7),
                    decoration: BoxDecoration(color: scheme.primary, shape: BoxShape.circle),
                    child: const Icon(Icons.add, color: Colors.white),
                  ),
                  label: 'Create',
                ),
                const NavigationDestination(
                  icon: Icon(Icons.file_download_outlined),
                  selectedIcon: Icon(Icons.file_download),
                  label: 'Exports',
                ),
                const NavigationDestination(
                  icon: Icon(Icons.settings_outlined),
                  selectedIcon: Icon(Icons.settings),
                  label: 'Settings',
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
