part of '../sidebar.dart';

class _ProjectIcon extends StatelessWidget {
  final Project project;
  final Color color;

  const _ProjectIcon({required this.project, required this.color});

  @override
  Widget build(BuildContext context) {
    final icon = projectIconForType(project.projectType);
    if (project.projectType == 'generic') {
      return Text(
        project.name.isNotEmpty ? project.name[0].toUpperCase() : '?',
        style: const TextStyle(
          fontSize: 12,
          color: Colors.white,
          fontWeight: FontWeight.w600,
        ),
      );
    }
    return Icon(icon.icon, size: 18, color: Colors.white);
  }
}
