import 'package:flutter/material.dart';

import '../api/api_service.dart';
import '../l10n/l10n.dart';
import '../models/models.dart';

/// A reusable folder browser matching the new-project folder picker.
///
/// It starts at the user's home directory, supports `~` and absolute paths,
/// and calls [onSelect] with the selected path. [homePrefix] controls how the
/// home root is displayed: `'~'` for clone root, `'.'` for project creation.
class FolderPicker extends StatefulWidget {
  final ApiService api;
  final TextEditingController? controller;
  final String? initialPath;
  final String homePrefix;
  final void Function(String path, bool isHomeRoot)? onSelect;

  const FolderPicker({
    super.key,
    required this.api,
    this.controller,
    this.initialPath,
    this.homePrefix = '~',
    this.onSelect,
  });

  @override
  State<FolderPicker> createState() => _FolderPickerState();
}

class _FolderPickerState extends State<FolderPicker> {
  late final TextEditingController _ownController;
  TextEditingController get _controller => widget.controller ?? _ownController;

  final _pathSegments = <String>[];
  var _isAbsolute = false;
  var _entries = <DirEntry>[];
  var _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _ownController = TextEditingController();
    _controller.text = widget.initialPath?.trim() ?? '';
    _jumpToTextPath();
  }

  @override
  void dispose() {
    _ownController.dispose();
    super.dispose();
  }

  String get _currentPath {
    if (_isAbsolute) {
      return _pathSegments.isEmpty ? '/' : '/${_pathSegments.join('/')}';
    }
    return _pathSegments.join('/');
  }

  String get _displayPath {
    if (_isAbsolute) {
      return _currentPath;
    }
    if (_pathSegments.isEmpty) return widget.homePrefix;
    if (widget.homePrefix == '.') {
      return _pathSegments.join('/');
    }
    return '~/${_pathSegments.join('/')}';
  }

  bool get _isHomeRoot => !_isAbsolute && _pathSegments.isEmpty;

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final path = _currentPath.isEmpty ? null : _currentPath;
      final entries = await widget.api.listFiles(
        path: path,
        projectId: null,
      );
      if (!mounted) return;
      setState(() {
        _entries = entries
            .where((e) => e.isDir && !e.name.startsWith('.'))
            .toList();
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  void _enter(String name) {
    _pathSegments.add(name);
    _load();
  }

  void _up() {
    if (_pathSegments.isEmpty) return;
    _pathSegments.removeLast();
    _load();
  }

  void _goTo(int index) {
    if (index < 0) {
      _pathSegments.clear();
    } else if (index < _pathSegments.length) {
      _pathSegments.removeRange(index + 1, _pathSegments.length);
    } else {
      return;
    }
    _load();
  }

  void _selectCurrent() {
    _controller.text = _displayPath;
    widget.onSelect?.call(_displayPath, _isHomeRoot);
  }

  void _jumpToTextPath() {
    setState(() => _error = null);
    final text = _controller.text.trim();

    if (text.isEmpty || text == widget.homePrefix) {
      _isAbsolute = false;
      _pathSegments.clear();
      _controller.text = widget.homePrefix;
      _load();
      return;
    }

    if (text == '~' || text.startsWith('~/') || text.startsWith('~\\')) {
      _isAbsolute = false;
      var rest = text;
      if (rest == '~') {
        rest = '';
      } else if (rest.startsWith('~/')) {
        rest = rest.substring(2);
      } else if (rest.startsWith('~\\')) {
        rest = rest.substring(2);
      }
      _pathSegments
        ..clear()
        ..addAll(rest
            .split(RegExp(r'[/\\]'))
            .where((s) => s.isNotEmpty && s != '.')
            .toList());
      _controller.text = _displayPath;
      _load();
      return;
    }

    if (text.contains('..')) {
      setState(() => _error = l10n(context).pathTraversalNotAllowed);
      return;
    }

    _isAbsolute = text.startsWith('/');
    _pathSegments
      ..clear()
      ..addAll(text
          .split('/')
          .where((s) => s.isNotEmpty && s != '.')
          .toList());
    _controller.text = _displayPath;
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _controller,
          decoration: InputDecoration(
            labelText: l10n(context).path,
            hintText: l10n(context).projectPathHint,
            border: const OutlineInputBorder(),
            suffixIcon: IconButton(
              tooltip: l10n(context).browseToThisPath,
              icon: const Icon(Icons.refresh, size: 18),
              onPressed: _jumpToTextPath,
            ),
          ),
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _jumpToTextPath(),
        ),
        const SizedBox(height: 8),
        _BrowserHeader(
          path: _currentPath,
          isAbsolute: _isAbsolute,
          onUp: _up,
          onCrumb: _goTo,
          enabled: !_loading,
        ),
        const SizedBox(height: 4),
        Flexible(
          child: Container(
            constraints: const BoxConstraints(maxHeight: 280),
            decoration: BoxDecoration(
              border: Border.all(color: theme.colorScheme.outlineVariant),
              borderRadius: BorderRadius.circular(12),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: _buildBrowser(theme),
            ),
          ),
        ),
        if (widget.onSelect != null) ...[
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: _selectCurrent,
              icon: const Icon(Icons.check, size: 18),
              label: Text(l10n(context).selectCurrentFolder),
            ),
          ),
        ],
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(
            _error!,
            style: TextStyle(color: theme.colorScheme.error),
          ),
        ],
      ],
    );
  }

  Widget _buildBrowser(ThemeData theme) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            _error!,
            textAlign: TextAlign.center,
            style: TextStyle(color: theme.colorScheme.error),
          ),
        ),
      );
    }
    if (_entries.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            l10n(context).noSubfoldersHere,
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
      );
    }
    return ListView.builder(
      shrinkWrap: true,
      itemCount: _entries.length,
      itemBuilder: (context, index) {
        final e = _entries[index];
        return ListTile(
          leading: Icon(Icons.folder,
              color: theme.colorScheme.primary, size: 20),
          title: Text(e.name, style: theme.textTheme.bodyMedium),
          dense: true,
          onTap: _loading ? null : () => _enter(e.name),
        );
      },
    );
  }
}

class _BrowserHeader extends StatelessWidget {
  final String path;
  final bool isAbsolute;
  final VoidCallback onUp;
  final ValueChanged<int> onCrumb;
  final bool enabled;

  const _BrowserHeader({
    required this.path,
    this.isAbsolute = false,
    required this.onUp,
    required this.onCrumb,
    required this.enabled,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final segs = path
        .split('/')
        .where((s) => s.isNotEmpty)
        .toList();
    final rootLabel = isAbsolute ? l10n(context).root : l10n(context).home;
    final crumbs = <String>[rootLabel, ...segs];

    return Row(
      children: [
        TextButton.icon(
          onPressed: enabled ? onUp : null,
          icon: const Icon(Icons.arrow_upward, size: 18),
          label: Text(l10n(context).up),
        ),
        const SizedBox(width: 4),
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (var i = 0; i < crumbs.length; i++) ...[
                  if (i > 0)
                    Text(l10n(context).breadcrumbSeparator,
                        style: theme.textTheme.labelMedium),
                  InkWell(
                    onTap: enabled ? () => onCrumb(i - 1) : null,
                    child: Text(
                      crumbs[i],
                      style: theme.textTheme.labelMedium?.copyWith(
                            color: enabled
                                ? theme.colorScheme.primary
                                : theme.colorScheme.onSurfaceVariant,
                            fontWeight: i == crumbs.length - 1
                                ? FontWeight.w600
                                : FontWeight.normal,
                          ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}
