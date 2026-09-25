part of '../sidebar.dart';

/// Dropdown that narrows the sidebar thread lists by run status.
/// [_ThreadStatusFilter.all] shows every thread.
class _StatusFilter extends StatelessWidget {
  final _ThreadStatusFilter value;
  final ValueChanged<_ThreadStatusFilter> onChanged;

  const _StatusFilter({required this.value, required this.onChanged});

  String _label(AppLocalizations l, _ThreadStatusFilter filter) {
    return switch (filter) {
      _ThreadStatusFilter.all => l.statusFilterAll,
      _ThreadStatusFilter.running => l.threadStatusWorking,
      _ThreadStatusFilter.done => l.threadStatusDone,
      _ThreadStatusFilter.failed => l.threadStatusFailed,
    };
  }

  Widget _dot(ThemeData theme, String tag) {
    final style = threadStatusStyle(theme, tag);
    return Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(color: style.color, shape: BoxShape.circle),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l = l10n(context);

    Widget item(_ThreadStatusFilter filter, {String? tag}) {
      return MenuItemButton(
        key: Key('status_filter_${filter.name}'),
        leadingIcon: tag == null
            ? const SizedBox(width: 8, height: 8)
            : _dot(theme, tag),
        trailingIcon: value == filter ? const Icon(Icons.check, size: 18) : null,
        onPressed: () => onChanged(filter),
        child: Text(_label(l, filter)),
      );
    }

    return MenuAnchor(
      onClose: () => _clearMenuFocus(context),
      menuChildren: [
        item(_ThreadStatusFilter.all),
        item(_ThreadStatusFilter.running, tag: 'running'),
        item(_ThreadStatusFilter.done, tag: 'done'),
        item(_ThreadStatusFilter.failed, tag: 'failed'),
      ],
      builder: (context, controller, child) {
        return Material(
          color: theme.colorScheme.surfaceContainer,
          borderRadius: BorderRadius.circular(8),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            key: const Key('status_filter'),
            onTap: () {
              if (controller.isOpen) {
                controller.close();
              } else {
                controller.open();
              }
            },
            child: SizedBox(
              height: 36,
              child: Row(
                children: [
                  const SizedBox(width: 10),
                  Icon(
                    Icons.filter_list,
                    size: 18,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _label(l, value),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium,
                    ),
                  ),
                  Icon(
                    Icons.arrow_drop_down,
                    size: 18,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 8),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
