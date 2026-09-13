part of '../sidebar.dart';

({Color color, IconData icon, String label}) _connectionStatusStyle(
  BuildContext context,
  ConnectionStatus status,
) {
  final theme = Theme.of(context);
  final l = l10n(context);
  final semantic = SemanticColors.of(context);

  return switch (status) {
    ConnectionStatus.connected => (
      color: semantic.success,
      icon: Icons.cloud_done,
      label: l.connected,
    ),
    ConnectionStatus.disconnected => (
      color: theme.colorScheme.error,
      icon: Icons.cloud_off,
      label: l.disconnected,
    ),
    ConnectionStatus.checking => (
      color: theme.colorScheme.onSurfaceVariant,
      icon: Icons.sync,
      label: l.checkingConnection,
    ),
  };
}

class _ConnectionStatusIcon extends StatelessWidget {
  const _ConnectionStatusIcon();

  @override
  Widget build(BuildContext context) {
    final status = context.select<AppState, ConnectionStatus>(
      (s) => s.connectionStatus,
    );
    final style = _connectionStatusStyle(context, status);

    final Widget indicator;
    if (status == ConnectionStatus.checking) {
      indicator = SizedBox(
        width: 14,
        height: 14,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          valueColor: AlwaysStoppedAnimation(style.color),
        ),
      );
    } else {
      indicator = Icon(style.icon, size: 16, color: style.color);
    }

    return Tooltip(
      message: style.label,
      child: Padding(
        padding: const EdgeInsets.only(right: 4),
        child: indicator,
      ),
    );
  }
}
