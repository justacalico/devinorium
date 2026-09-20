part of '../sidebar.dart';

class _ProjectIcon extends StatelessWidget {
  final Project project;

  const _ProjectIcon({required this.project});

  @override
  Widget build(BuildContext context) {
    final api = context.select<AppState, ApiService>((s) => s.api);
    return FutureBuilder<({String mime, Uint8List bytes})?>(
      future: api.projectIcon(project.id),
      builder: (context, snapshot) {
        final icon = snapshot.data;
        if (icon == null) return _typeIcon();
        return ProjectIconImage(icon: icon, fallback: _typeIcon());
      },
    );
  }

  Widget _typeIcon() {
    final icon = projectIconForType(project.projectType);
    if (project.projectType == 'generic') {
      return Text(
        project.name.isEmpty
            ? '?'
            : project.name.characters.first.toUpperCase(),
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
