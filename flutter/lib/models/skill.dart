/// A skill discoverable in a thread's working directory, offered by the
/// composer `/` picker.
class Skill {
  final String name;
  final String description;
  final String argumentHint;

  /// `project` for cwd-scoped skills, `user` for global ones.
  final String source;

  const Skill({
    required this.name,
    this.description = '',
    this.argumentHint = '',
    this.source = 'project',
  });

  factory Skill.fromJson(Map<String, dynamic> j) => Skill(
    name: j['name'] as String? ?? '',
    description: j['description'] as String? ?? '',
    argumentHint: j['argument_hint'] as String? ?? '',
    source: j['source'] as String? ?? 'project',
  );
}
