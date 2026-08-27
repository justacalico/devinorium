part of '../sidebar.dart';

class _ConnectionStatusIcon extends StatelessWidget {
  const _ConnectionStatusIcon();

  @override
  Widget build(BuildContext context) {
    final status = context.select<AppState, ConnectionStatus>(
      (s) => s.connectionStatus,
    );
    final theme = Theme.of(context);
    final l = l10n(context);

    final (Color color, IconData icon, String label) = switch (status) {
      ConnectionStatus.connected =>
        (Colors.green, Icons.cloud_done, l.connected),
      ConnectionStatus.disconnected =>
        (theme.colorScheme.error, Icons.cloud_off, l.disconnected),
      ConnectionStatus.checking =>
        (theme.colorScheme.onSurfaceVariant, Icons.sync, l.checkingConnection),
    };

    final Widget indicator;
    if (status == ConnectionStatus.checking) {
      indicator = SizedBox(
        width: 14,
        height: 14,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          valueColor: AlwaysStoppedAnimation(color),
        ),
      );
    } else {
      indicator = Icon(icon, size: 16, color: color);
    }

    return Tooltip(
      message: label,
      child: Padding(
        padding: const EdgeInsets.only(right: 4),
        child: indicator,
      ),
    );
  }
}
