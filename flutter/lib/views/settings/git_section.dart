part of '../settings_page.dart';

class _GitSection extends StatefulWidget {
  final AppState state;

  const _GitSection({required this.state});

  @override
  State<_GitSection> createState() => _GitSectionState();
}

class _GitSectionState extends State<_GitSection> {
  bool _busy = false;

  static const _gitlabId = 'gitlab';
  static const _githubId = 'github';

  Future<void> _connect(GitConnection connection) async {
    setState(() => _busy = true);
    if (connection.id == _githubId) {
      await widget.state.connectGitHub();
    } else {
      await widget.state.connectGitLab();
    }
    if (mounted) {
      setState(() => _busy = false);
      if (widget.state.globalError.isNotEmpty) {
        final l = l10n(context);
        showAppMessage(
          context,
          connection.id == _githubId
              ? l.githubConnectFailed(widget.state.globalError)
              : l.gitlabConnectFailed(widget.state.globalError),
          kind: MessageKind.error,
        );
      }
    }
  }

  Future<void> _disconnect(GitConnection connection) async {
    setState(() => _busy = true);
    if (connection.id == _githubId) {
      await widget.state.disconnectGitHub(hostname: connection.host);
    } else {
      await widget.state.disconnectGitLab(hostname: connection.host);
    }
    if (mounted) {
      setState(() => _busy = false);
      if (widget.state.globalError.isNotEmpty) {
        final l = l10n(context);
        showAppMessage(
          context,
          connection.id == _githubId
              ? l.githubDisconnectFailed(widget.state.globalError)
              : l.gitlabDisconnectFailed(widget.state.globalError),
          kind: MessageKind.error,
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l = l10n(context);

    return Selector<AppState, ({
      List<GitConnection> connections,
      bool loading,
      String globalError,
    })>(
      selector: (_, s) => (
        connections: s.gitConnections,
        loading: s.loadingGitConnections,
        globalError: s.globalError,
      ),
      builder: (context, model, _) {
        final connections = model.connections;
        final isLoading = model.loading;

        List<Widget> children = [];

        if (model.globalError.isNotEmpty && !model.loading) {
          children.add(
            Text(
              model.globalError,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.error),
            ),
          );
          children.add(const SizedBox(height: 16));
        }

        if (isLoading && connections.isEmpty) {
          children.add(Text(l.loading));
        } else if (connections.isEmpty) {
          children.add(Text(l.gitConnections));
        } else {
          for (final conn in connections) {
            if (conn.id == _gitlabId) {
              children.add(_buildGitLabRow(context, theme, l, conn));
            } else if (conn.id == _githubId) {
              children.add(_buildGitHubRow(context, theme, l, conn));
            } else {
              children.add(_buildGenericRow(context, theme, l, conn));
            }
            children.add(const SizedBox(height: 16));
          }
        }

        return _SectionCard(
          title: l.git,
          children: children,
        );
      },
    );
  }

  Widget _buildGitLabRow(
    BuildContext context,
    ThemeData theme,
    AppLocalizations l,
    GitConnection conn,
  ) {
    final status = conn.authed
        ? (conn.host != null
            ? '${l.connectedAs(conn.account ?? '')} (${conn.host})'
            : l.connectedAs(conn.account ?? ''))
        : l.notConnected;

    if (!conn.enabled) {
      return GitProviderTile(
        icon: GitLabIcon(color: theme.colorScheme.onSurfaceVariant),
        title: l.gitlab,
        subtitle: l.gitlabNotInstalled,
      );
    }

    if (conn.authed) {
      return GitProviderTile(
        icon: const GitLabIcon(),
        title: l.gitlab,
        subtitle: status,
        subtitleColor: theme.colorScheme.primary,
        trailing: _busy
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : OutlinedButton(
                onPressed: () => _disconnect(conn),
                child: Text(l.disconnect),
              ),
      );
    }

    return GitProviderTile(
      icon: const GitLabIcon(),
      title: l.gitlab,
      subtitle: l.gitlabConnectHint,
      trailing: _busy
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : FilledButton(
              onPressed: () => _connect(conn),
              child: Text(l.connect),
            ),
    );
  }

  Widget _buildGitHubRow(
    BuildContext context,
    ThemeData theme,
    AppLocalizations l,
    GitConnection conn,
  ) {
    final status = conn.authed
        ? (conn.host != null
            ? '${l.connectedAs(conn.account ?? '')} (${conn.host})'
            : l.connectedAs(conn.account ?? ''))
        : l.notConnected;

    if (!conn.enabled) {
      return GitProviderTile(
        icon: GitHubIcon(color: theme.colorScheme.onSurfaceVariant),
        title: l.github,
        subtitle: l.githubNotInstalled,
      );
    }

    if (conn.authed) {
      return GitProviderTile(
        icon: const GitHubIcon(),
        title: l.github,
        subtitle: status,
        subtitleColor: theme.colorScheme.primary,
        trailing: _busy
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : OutlinedButton(
                onPressed: () => _disconnect(conn),
                child: Text(l.disconnect),
              ),
      );
    }

    return GitProviderTile(
      icon: const GitHubIcon(),
      title: l.github,
      subtitle: l.githubConnectHint,
      trailing: _busy
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : FilledButton(
              onPressed: () => _connect(conn),
              child: Text(l.connect),
            ),
    );
  }

  Widget _buildGenericRow(
    BuildContext context,
    ThemeData theme,
    AppLocalizations l,
    GitConnection conn,
  ) {
    return GitProviderTile(
      icon: Icon(Icons.code, color: theme.colorScheme.onSurface),
      title: conn.name,
      subtitle: conn.comingSoon
          ? l.comingSoon
          : (conn.authed
              ? l.connectedAs(conn.account ?? '')
              : l.notConnected),
    );
  }
}
