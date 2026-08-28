part of '../settings_page.dart';

class _DevicesSection extends StatefulWidget {
  final AppState state;

  const _DevicesSection({required this.state});

  @override
  State<_DevicesSection> createState() => _DevicesSectionState();
}

class _DevicesSectionState extends State<_DevicesSection> {
  Future<void> _revoke(String token) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n(context).revokeDeviceTitle),
        content: Text(l10n(context).revokeDeviceBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n(context).cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n(context).revoke),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await widget.state.revokeDevice(token);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l = l10n(context);
    return _SectionCard(
      title: l.devices,
      children: [
        Text(
          l.devicesDescription,
          style: theme.textTheme.bodyMedium
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const Divider(),
        ListenableBuilder(
          listenable: widget.state,
          builder: (context, child) {
            final devices = widget.state.devices;
            if (devices.isEmpty) {
              return Text(
                l.noPairedDevices,
                style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant),
              );
            }
            return ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: devices.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (_, i) => _DeviceRow(
                device: devices[i],
                onRevoke: _revoke,
              ),
            );
          },
        ),
      ],
    );
  }
}

class _DeviceRow extends StatelessWidget {
  final Device device;
  final void Function(String) onRevoke;

  const _DeviceRow({required this.device, required this.onRevoke});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final display = device.name?.isNotEmpty == true
        ? device.name!
        : l10n(context).deviceToken(device.tokenPrefix);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  display,
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(fontWeight: FontWeight.w500),
                ),
                Text(
                  device.isCurrent ? l10n(context).current : l10n(context).paired,
                  style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
          if (!device.isCurrent)
            IconButton(
              icon: const Icon(Icons.logout, size: 20),
              tooltip: l10n(context).revoke,
              onPressed: () => onRevoke(device.deviceId),
            ),
        ],
      ),
    );
  }
}
