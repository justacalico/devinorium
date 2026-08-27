part of '../thread_page.dart';

class _PermissionDropdown extends StatelessWidget {
  final String value;
  final ValueChanged<String> onChanged;
  final bool enabled;
  const _PermissionDropdown({
    required this.value,
    required this.onChanged,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    final l = l10n(context);
    final modes = [
      ('normal', l.permissionModeNormal),
      ('accept-edits', l.permissionModeAcceptEdits),
      ('smart', l.permissionModeSmart),
      ('bypass', l.permissionModeBypass),
    ];
    final fallback = !modes.any((m) => m.$1 == value)
        ? [DropdownMenuItem<String>(value: value, child: Text(value))]
        : <DropdownMenuItem<String>>[];
    final items = [
      for (final (id, label) in modes)
        DropdownMenuItem<String>(value: id, child: Text(label)),
      ...fallback,
    ];
    final effectiveValue = items.any((i) => i.value == value) ? value : null;

    return DropdownButton<String>(
      value: effectiveValue,
      underline: const SizedBox(),
      isDense: true,
      items: items,
      onChanged: enabled
          ? (v) {
              if (v != null) onChanged(v);
            }
          : null,
    );
  }
}
