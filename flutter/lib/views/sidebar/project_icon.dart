part of '../sidebar.dart';

class _ProjectIcon extends StatelessWidget {
  final Project project;
  final Color color;

  const _ProjectIcon({required this.project, required this.color});

  @override
  Widget build(BuildContext context) {
    final icon = projectIconForType(project.projectType);
    // For generic projects, fall back to the first-letter avatar.
    if (project.projectType == 'generic') {
      return Text(
        project.name.isNotEmpty ? project.name[0].toUpperCase() : '?',
        style: const TextStyle(
          fontSize: 14,
          color: Colors.white,
          fontWeight: FontWeight.w600,
        ),
      );
    }
    return Icon(icon.icon, size: 20, color: Colors.white);
  }
}
