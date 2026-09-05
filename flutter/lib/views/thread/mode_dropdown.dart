part of '../thread_page.dart';

class _ModeDropdown extends StatelessWidget {
  final ComposerMode value;
  final ValueChanged<ComposerMode> onChanged;
  final bool enabled;
  final bool compact;
  const _ModeDropdown({
    required this.value,
    required this.onChanged,
    this.enabled = true,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final items = [
      for (final mode in ComposerMode.values)
        DropdownMenuItem<ComposerMode>(
          value: mode,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(_modeIcon(mode), size: 14),
              const SizedBox(width: 6),
              Text(mode.label),
            ],
          ),
        ),
    ];

    return DropdownButton<ComposerMode>(
      value: value,
      underline: const SizedBox(),
      isDense: true,
      iconSize: 16,
      padding: compact ? const EdgeInsets.symmetric(horizontal: 4) : null,
      style: Theme.of(context).textTheme.bodyMedium,
      selectedItemBuilder: compact
          ? (_) => [
              for (final mode in ComposerMode.values)
                Text(
                  mode.label,
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.ellipsis,
                ),
            ]
          : null,
      items: items,
      onChanged: enabled
          ? (v) {
              if (v != null) onChanged(v);
            }
          : null,
    );
  }

  static IconData _modeIcon(ComposerMode mode) => switch (mode) {
    ComposerMode.code => Icons.code,
    ComposerMode.plan => Icons.lightbulb_outline,
    ComposerMode.ask => Icons.help_outline,
  };
}
