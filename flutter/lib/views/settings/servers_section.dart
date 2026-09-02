part of '../settings_page.dart';

class _ServersSection extends StatelessWidget {
  const _ServersSection();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);

    if (kIsWeb) {
      return _SectionCard(
        title: 'Servers',
        children: [
          Text(
            'Server switching is not available in the web build.',
            style: theme.textTheme.bodyMedium,
          ),
        ],
      );
    }

    final l = l10n(context);

    return _SectionCard(
      title: l.servers,
      children: [
        if (state.serverProfiles.isEmpty)
          Text(
            'No servers configured.',
            style: theme.textTheme.bodyMedium,
          )
        else
          ListView.separated(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: state.serverProfiles.length,
            separatorBuilder: (context, index) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final profile = state.serverProfiles[index];
              final isActive = profile.id == state.activeServerId;
              final leading = isActive
                  ? Icon(Icons.check_circle,
                      color: theme.colorScheme.primary)
                  : const Icon(Icons.circle_outlined);
              return ListTile(
                leading: leading,
                title: Text(profile.label),
                subtitle:
                    Text(profile.baseUrl.isEmpty ? 'web' : profile.baseUrl),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (!isActive)
                      TextButton(
                        onPressed: () =>
                            unawaited(state.switchServer(profile.id)),
                        child: const Text('Switch'),
                      ),
                    IconButton(
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () =>
                          unawaited(state.removeServer(profile.id)),
                      tooltip: 'Remove',
                    ),
                  ],
                ),
              );
            },
          ),
        const SizedBox(height: 16),
        FilledButton.tonal(
          onPressed: () => _showAddServerDialog(context, state),
          child: const Text('Add server'),
        ),
      ],
    );
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
  final _url = TextEditingController();
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _totp = TextEditingController();
  bool _showTotp = false;
  String _error = '';
  bool _loading = false;

  @override
  void dispose() {
    _url.dispose();
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
      final url = _url.text.trim();
      if (!url.startsWith('http://') && !url.startsWith('https://')) {
        throw FormatException('URL must start with http:// or https://');
      }
      await widget.state.addServer(
        serverUrl: url,
        username: _username.text.trim(),
        password: _password.text,
        totp: _showTotp ? _totp.text.trim() : null,
      );
      if (mounted) {
        if (widget.state.globalError.isNotEmpty) {
          setState(() {
            _error = widget.state.globalError;
            _loading = false;
            // If the error hints at TOTP, show the field.
            if (_error.contains('TOTP') || _error.contains('totp')) {
              _showTotp = true;
            }
          });
          return;
        }
        if (widget.state.serverProfiles.isNotEmpty) {
          Navigator.of(context).pop();
        }
      }
    } on FormatException catch (e) {
      if (mounted) {
        setState(() {
          _error = e.message;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '$e';
        });
      }
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add server'),
      content: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: _url,
                decoration: const InputDecoration(
                  labelText: 'Server URL',
                  hintText: 'http://localhost:7878',
                ),
                validator: (v) =>
                    v == null || v.trim().isEmpty ? 'Required' : null,
                enabled: !_loading,
              ),
              TextFormField(
                controller: _username,
                decoration: const InputDecoration(labelText: 'Username'),
                validator: (v) =>
                    v == null || v.trim().isEmpty ? 'Required' : null,
                enabled: !_loading,
              ),
              TextFormField(
                controller: _password,
                decoration: const InputDecoration(labelText: 'Password'),
                obscureText: true,
                validator: (v) => v == null || v.isEmpty ? 'Required' : null,
                enabled: !_loading,
              ),
              if (_showTotp)
                TextFormField(
                  controller: _totp,
                  decoration: const InputDecoration(
                    labelText: 'TOTP code',
                    hintText: '000000',
                  ),
                  validator: (v) =>
                      v == null || v.trim().isEmpty ? 'Required' : null,
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
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: _loading ? null : _submit,
          child: _loading
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Sign in'),
        ),
      ],
    );
  }
}
