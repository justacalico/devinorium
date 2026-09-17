part of '../settings_page.dart';

class _ServersSection extends StatelessWidget {
  const _ServersSection();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l = l10n(context);
    final state = context.read<AppState>();

    return Selector<
      AppState,
      ({
        String? serverVersion,
        List<ServerProfile> serverProfiles,
        String? activeServerId,
      })
    >(
      selector: (_, s) => (
        serverVersion: s.serverVersion,
        serverProfiles: s.serverProfiles,
        activeServerId: s.activeServerId,
      ),
      builder: (context, model, _) {
        final version = model.serverVersion;
        final versionWidgets = version != null && version.isNotEmpty
            ? <Widget>[
                _SettingsRow(label: l.serverVersion, value: version),
                const Divider(),
              ]
            : <Widget>[];

        if (kIsWeb) {
          return Column(
            children: [
              _SectionCard(
                title: l.servers,
                children: [
                  ...versionWidgets,
                  Text(
                    l.serverSwitchNotAvailableWeb,
                    style: theme.textTheme.bodyMedium,
                  ),
                ],
              ),
              const _ServerUpdateSection(),
              const _TailscaleSection(),
              const _MachinesSection(),
            ],
          );
        }

        return Column(
          children: [
            _SectionCard(
              title: l.servers,
              children: [
                ...versionWidgets,
                if (model.serverProfiles.isEmpty)
                  Text(l.noServersConfigured, style: theme.textTheme.bodyMedium)
                else
                  ListView.separated(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: model.serverProfiles.length,
                    separatorBuilder: (context, index) =>
                        const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final profile = model.serverProfiles[index];
                      final isActive = profile.id == model.activeServerId;
                      final leading = isActive
                          ? Icon(
                              Icons.check_circle,
                              color: theme.colorScheme.primary,
                            )
                          : const Icon(Icons.circle_outlined);
                      var displayUrl = profile.baseUrl.isEmpty
                          ? l.web
                          : profile.baseUrl;
                      for (final scheme in ['https://', 'http://']) {
                        if (displayUrl.startsWith(scheme)) {
                          displayUrl = displayUrl.substring(scheme.length);
                          break;
                        }
                      }
                      final title = profile.isLocal
                          ? l.thisDevice
                          : (profile.username.isEmpty
                                ? profile.label
                                : profile.username);
                      final subtitle = profile.isLocal
                          ? l.bundledServer
                          : displayUrl;
                      return ListTile(
                        leading: leading,
                        title: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          softWrap: false,
                        ),
                        subtitle: Tooltip(
                          message: profile.baseUrl.isEmpty
                              ? displayUrl
                              : profile.baseUrl,
                          child: Text(
                            subtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            softWrap: false,
                          ),
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (!isActive)
                              TextButton(
                                onPressed: () =>
                                    unawaited(state.switchServer(profile.id)),
                                child: Text(l.switchServerLabel),
                              ),
                            if (!profile.isLocal)
                              IconButton(
                                icon: const Icon(Icons.delete_outline),
                                tooltip: l.delete,
                                onPressed: () => unawaited(
                                  _confirmAndRemove(context, state, profile),
                                ),
                              ),
                          ],
                        ),
                      );
                    },
                  ),
                const SizedBox(height: 16),
                FilledButton.tonal(
                  onPressed: () =>
                      unawaited(_showAddServerDialog(context, state)),
                  child: Text(l.addServer),
                ),
              ],
            ),
            const _ServerUpdateSection(),
            const _TailscaleSection(),
            const _MachinesSection(),
          ],
        );
      },
    );
  }

  Future<void> _confirmAndRemove(
    BuildContext context,
    AppState state,
    ServerProfile profile,
  ) async {
    final l = l10n(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        content: Text(l.deleteServerConfirm(profile.label)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l.delete),
          ),
        ],
      ),
    );
    if (confirmed == true && context.mounted) {
      await state.removeServer(profile.id);
    }
  }

  Future<void> _showAddServerDialog(
    BuildContext context,
    AppState state,
  ) async {
    await showDialog<void>(
      context: context,
      builder: (_) => _AddServerDialog(state: state),
    );
  }
}

class _AddServerDialog extends StatefulWidget {
  const _AddServerDialog({required this.state});

  final AppState state;

  @override
  State<_AddServerDialog> createState() => _AddServerDialogState();
}

class _AddServerDialogState extends State<_AddServerDialog> {
  final _formKey = GlobalKey<FormState>();
  final _host = TextEditingController();
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _totp = TextEditingController();
  String _scheme = 'https://';
  bool _showTotp = false;
  String _error = '';
  bool _loading = false;

  @override
  void dispose() {
    _host.dispose();
    _username.dispose();
    _password.dispose();
    _totp.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _error = '';
      _loading = true;
    });
    try {
      final l = l10n(context);
      final error = await widget.state.addServer(
        serverUrl: '$_scheme${_host.text.trim()}',
        username: _username.text.trim(),
        password: _password.text,
        totp: _totp.text.trim().isEmpty ? null : _totp.text.trim(),
      );
      if (!mounted) return;
      if (error != null) {
        setState(() {
          _error = error;
          _showTotp = _showTotp || error == l.totpPrompt;
        });
        return;
      }
      Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        setState(() => _error = '$e');
      }
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = l10n(context);

    String? validateHost(String? value) {
      final trimmed = value?.trim() ?? '';
      if (trimmed.isEmpty) return l.required;
      if (trimmed.contains('://') || trimmed.contains(' ')) {
        return l.serverUrlInvalid;
      }
      return null;
    }

    String? validateRequired(String? value) {
      return value == null || value.trim().isEmpty ? l.required : null;
    }

    String? validatePassword(String? value) {
      return value == null || value.isEmpty ? l.required : null;
    }

    return AlertDialog(
      title: Text(l.addServer),
      content: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 104,
                    child: DropdownButtonFormField<String>(
                      initialValue: _scheme,
                      isExpanded: true,
                      items: const [
                        DropdownMenuItem(
                          value: 'https://',
                          child: Text('https://'),
                        ),
                        DropdownMenuItem(
                          value: 'http://',
                          child: Text('http://'),
                        ),
                      ],
                      onChanged: _loading
                          ? null
                          : (v) {
                              if (v != null) setState(() => _scheme = v);
                            },
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextFormField(
                      controller: _host,
                      decoration: InputDecoration(
                        labelText: l.serverUrl,
                        hintText: l.serverUrlHint,
                      ),
                      keyboardType: TextInputType.url,
                      validator: validateHost,
                      enabled: !_loading,
                    ),
                  ),
                ],
              ),
              TextFormField(
                controller: _username,
                decoration: InputDecoration(labelText: l.username),
                validator: validateRequired,
                enabled: !_loading,
              ),
              TextFormField(
                controller: _password,
                decoration: InputDecoration(labelText: l.password),
                obscureText: true,
                validator: validatePassword,
                enabled: !_loading,
              ),
              TextFormField(
                controller: _totp,
                decoration: InputDecoration(
                  labelText: l.totpCode,
                  hintText: l.totpHint,
                  helperText: _showTotp ? null : l.totpOptional,
                ),
                validator: _showTotp ? validateRequired : null,
                keyboardType: TextInputType.number,
                enabled: !_loading,
              ),
              if (_error.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  _error,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _loading ? null : () => Navigator.of(context).pop(),
          child: Text(l.cancel),
        ),
        TextButton(
          onPressed: _loading ? null : () => unawaited(_submit()),
          child: _loading
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(l.addServer),
        ),
      ],
    );
  }
}

/// Owner-only card for updating the connected server itself: check GitLab
/// releases for a newer build, then download, verify, and restart into it.
/// The bundled desktop server and dev builds report themselves as not
/// updatable; the check response carries the reason.
class _ServerUpdateSection extends StatefulWidget {
  const _ServerUpdateSection();

  @override
  State<_ServerUpdateSection> createState() => _ServerUpdateSectionState();
}

class _ServerUpdateSectionState extends State<_ServerUpdateSection> {
  bool _checking = false;
  bool _applying = false;
  bool _checkFailed = false;
  String? _appliedVersion;
  ServerUpdateCheck? _check;
  String? _applyError;

  /// The server the last check ran against; switching servers resets the
  /// card so a result cannot leak onto a different backend.
  String? _checkedServerId;

  /// Set once the connection drops after an update; clearing
  /// `_appliedVersion` waits for a real disconnect so the spinner does not
  /// vanish before the restart even starts.
  bool _sawDrop = false;

  Future<void> _checkForUpdate(AppState state) async {
    if (_checking || _applying || _appliedVersion != null) return;
    final serverId = state.activeServerId;
    setState(() {
      _checking = true;
      _checkFailed = false;
      _applyError = null;
    });
    try {
      final check = await state.api.checkServerUpdate();
      if (!mounted || state.activeServerId != serverId) return;
      setState(() => _check = check);
    } catch (_) {
      if (!mounted || state.activeServerId != serverId) return;
      setState(() {
        _check = null;
        _checkFailed = true;
      });
    } finally {
      if (mounted && state.activeServerId == serverId) {
        setState(() => _checking = false);
      }
    }
  }

  Future<void> _apply(AppState state) async {
    final check = _check;
    if (_applying || check == null || !check.updateAvailable) return;
    // The apply runs against the server it was confirmed for even if the
    // user switches servers while the dialog is open.
    final serverId = state.activeServerId;
    final api = state.api;
    final l = l10n(context);
    final version = check.latestVersion ?? check.latestTag ?? '';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l.serverUpdate),
        content: Text(l.serverUpdateConfirm(version)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l.serverUpdateApply),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _applying = true;
      _applyError = null;
    });
    try {
      final installed = await api.applyServerUpdate();
      if (!mounted || state.activeServerId != serverId) return;
      // The server drops the connection and execs the new binary; the
      // health-check loop reconnects it and refreshes the version row.
      setState(() {
        _appliedVersion = installed;
        _sawDrop = false;
        _check = null;
      });
      showAppMessage(
        context,
        l.serverUpdateRestarting(installed),
        kind: MessageKind.success,
      );
    } catch (e) {
      if (!mounted || state.activeServerId != serverId) return;
      setState(() => _applyError = '$e');
    } finally {
      if (mounted && state.activeServerId == serverId) {
        setState(() => _applying = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l = l10n(context);
    final state = context.read<AppState>();

    return Selector<
      AppState,
      ({
        bool isOwner,
        String? activeServerId,
        ConnectionStatus connection,
        String? serverVersion,
      })
    >(
      selector: (_, s) => (
        isOwner: s.isOwner,
        activeServerId: s.activeServerId,
        connection: s.connectionStatus,
        serverVersion: s.serverVersion,
      ),
      builder: (context, model, _) {
        // The endpoints are owner-only; hide the card instead of showing a
        // button that always 403s.
        if (!model.isOwner) return const SizedBox.shrink();
        if (model.activeServerId != _checkedServerId) {
          _checkedServerId = model.activeServerId;
          _check = null;
          _checkFailed = false;
          _applyError = null;
          _appliedVersion = null;
          _sawDrop = false;
          // In-flight work targets the old server and discards its result,
          // so the busy flags are safe to clear here.
          _checking = false;
          _applying = false;
        }

        // The card stays on "restarting" until the backend actually drops
        // and reconnects or reports the new version; then it returns to
        // the normal check state.
        if (_appliedVersion != null) {
          if (model.connection == ConnectionStatus.disconnected) {
            _sawDrop = true;
          }
          final reconnected =
              model.connection == ConnectionStatus.connected &&
              model.serverVersion != null;
          if (model.serverVersion == _appliedVersion ||
              (_sawDrop && reconnected)) {
            _appliedVersion = null;
            _sawDrop = false;
          }
        }

        final busy = _checking || _applying || _appliedVersion != null;
        final check = _check;

        final Widget status;
        if (_appliedVersion != null) {
          status = Text(
            l.serverUpdateRestarting(_appliedVersion!),
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          );
        } else if (_applying) {
          status = Text(
            l.serverUpdateApplying,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          );
        } else if (_applyError != null) {
          status = Text(
            l.serverUpdateFailed(_applyError!),
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.error,
            ),
          );
        } else if (_checkFailed) {
          status = Text(
            l.serverUpdateCheckFailed,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.error,
            ),
          );
        } else if (check == null) {
          status = Text(
            l.serverUpdateHint,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          );
        } else if (!check.updatable) {
          final reason = switch (check.reason) {
            'local_mode' => l.serverUpdateLocalMode,
            'dev_mode' => l.serverUpdateDevMode,
            _ => l.serverUpdateUnsupported,
          };
          status = Text(
            reason,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          );
        } else if (check.updateAvailable) {
          status = Text(
            l.serverUpdateAvailable(check.latestVersion ?? ''),
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.primary,
              fontWeight: FontWeight.w500,
            ),
          );
        } else {
          status = Text(
            l.serverUpdateUpToDate,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          );
        }

        final updateReady =
            check != null && check.updatable && check.updateAvailable;
        final label = updateReady ? l.serverUpdateApply : l.serverUpdateCheck;
        return _SectionCard(
          title: l.serverUpdate,
          children: [
            Row(
              children: [
                Expanded(child: status),
                if (busy)
                  const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else if (check != null && !check.updatable)
                  const SizedBox.shrink()
                else
                  FilledButton.tonal(
                    key: updateReady
                        ? const Key('server_update_apply_button')
                        : const Key('server_update_check_button'),
                    onPressed: () => unawaited(
                      updateReady ? _apply(state) : _checkForUpdate(state),
                    ),
                    child: Text(label),
                  ),
              ],
            ),
          ],
        );
      },
    );
  }
}
