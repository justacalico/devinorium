part of '../settings_page.dart';

class _ServersSection extends StatelessWidget {
  const _ServersSection();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l = l10n(context);
    final state = context.read<AppState>();

    return Selector<AppState, ({
      String? serverVersion,
      List<ServerProfile> serverProfiles,
      String? activeServerId,
    })>(
      selector: (_, s) => (
        serverVersion: s.serverVersion,
        serverProfiles: s.serverProfiles,
        activeServerId: s.activeServerId,
      ),
      builder: (context, model, _) {
        final version = model.serverVersion;
        final versionWidgets = version != null && version.isNotEmpty
            ? <Widget>[
                _SettingsRow(
                  label: l.serverVersion,
                  value: version,
                ),
                const Divider(),
              ]
            : <Widget>[];

        if (kIsWeb) {
          return _SectionCard(
            title: l.servers,
            children: [
              ...versionWidgets,
              Text(
                l.serverSwitchNotAvailableWeb,
                style: theme.textTheme.bodyMedium,
              ),
            ],
          );
        }

        return _SectionCard(
          title: l.servers,
          children: [
            ...versionWidgets,
            if (model.serverProfiles.isEmpty)
              Text(
                l.noServersConfigured,
                style: theme.textTheme.bodyMedium,
              )
            else
              ListView.separated(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: model.serverProfiles.length,
                separatorBuilder: (context, index) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final profile = model.serverProfiles[index];
                  final isActive = profile.id == model.activeServerId;
                  final leading = isActive
                      ? Icon(Icons.check_circle,
                          color: theme.colorScheme.primary)
                      : const Icon(Icons.circle_outlined);
                  var displayUrl =
                      profile.baseUrl.isEmpty ? l.web : profile.baseUrl;
                  for (final scheme in ['https://', 'http://']) {
                    if (displayUrl.startsWith(scheme)) {
                      displayUrl = displayUrl.substring(scheme.length);
                      break;
                    }
                  }
                  final title =
                      profile.username.isEmpty ? profile.label : profile.username;
                  return ListTile(
                    leading: leading,
                    title: Text(title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        softWrap: false),
                    subtitle: Tooltip(
                      message: profile.baseUrl.isEmpty
                          ? displayUrl
                          : profile.baseUrl,
                      child: Text(displayUrl,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          softWrap: false),
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
                        IconButton(
                          icon: const Icon(Icons.delete_outline),
                          tooltip: l.delete,
                          onPressed: () =>
                              unawaited(_confirmAndRemove(context, state, profile)),
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

  Future<void> _showAddServerDialog(BuildContext context, AppState state) async {
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
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                  ),
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
