part of '../thread_page.dart';

/// `/` picker listing the skills the active thread's working directory
/// exposes. Picking one completes the `/name` token; the message still
/// sends as plain text — devin-cli resolves it natively, other providers
/// get the skill body expanded on the backend.
class _SkillPicker extends StatelessWidget {
  final List<Skill> skills;
  final int highlight;
  final bool noneFound;
  final ValueChanged<Skill> onPick;

  const _SkillPicker({
    super.key,
    required this.skills,
    required this.highlight,
    required this.noneFound,
    required this.onPick,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l = l10n(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Container(
        constraints: const BoxConstraints(maxHeight: 232),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: theme.colorScheme.outlineVariant),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
              child: Row(
                children: [
                  Icon(
                    Icons.bolt_outlined,
                    size: 14,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    l.skillPickerHint,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            if (skills.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
                child: Text(
                  noneFound ? l.skillsEmpty : l.skillPickerEmpty,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              )
            else
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  padding: EdgeInsets.zero,
                  itemCount: skills.length,
                  itemExtent: 40,
                  itemBuilder: (context, i) {
                    final s = skills[i];
                    final active = i == highlight;
                    return InkWell(
                      key: Key('skill_option_${s.name}'),
                      onTap: () => onPick(s),
                      child: Container(
                        color: active
                            ? theme.colorScheme.primaryContainer
                            : null,
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Row(
                          children: [
                            Icon(
                              s.source == 'user'
                                  ? Icons.person_outline
                                  : Icons.folder_outlined,
                              size: 14,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              '/${s.name}',
                              style: theme.textTheme.bodyMedium?.copyWith(
                                fontFamily: 'monospace',
                              ),
                            ),
                            if (s.argumentHint.isNotEmpty) ...[
                              const SizedBox(width: 6),
                              Text(
                                s.argumentHint,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                  fontFamily: 'monospace',
                                ),
                              ),
                            ],
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                s.description,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}
