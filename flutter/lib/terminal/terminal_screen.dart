import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../api/api_service.dart';
import 'terminal_grid.dart';
import 'terminal_session.dart';

/// Full-screen terminal page for a thread. Supports multiple local and/or
/// remote sessions shown in a grid.
class TerminalScreen extends StatefulWidget {
  const TerminalScreen({
    super.key,
    required this.api,
    required this.threadId,
  });

  final ApiService api;
  final String threadId;

  @override
  State<TerminalScreen> createState() => _TerminalScreenState();
}

class _TerminalScreenState extends State<TerminalScreen> {
  final _sessions = <TerminalSession>[];
  bool _busy = false;

  bool get _canUseLocalTerminal =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.linux ||
          defaultTargetPlatform == TargetPlatform.macOS ||
          defaultTargetPlatform == TargetPlatform.windows);

  Future<void> _addSession({required bool local}) async {
    setState(() => _busy = true);
    try {
      final session = await createTerminalSession(
        api: widget.api,
        threadId: widget.threadId,
        local: local,
      );
      session.addListener(_onSessionUpdate);
      if (mounted) setState(() => _sessions.add(session));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to start terminal: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _onSessionUpdate() => setState(() {});

  void _removeSession(TerminalSession session) {
    session.removeListener(_onSessionUpdate);
    setState(() => _sessions.remove(session));
    WidgetsBinding.instance.addPostFrameCallback((_) => session.dispose());
  }

  void _closeAll() {
    for (final s in _sessions) {
      s.removeListener(_onSessionUpdate);
    }
    final toDispose = _sessions.toList();
    setState(() => _sessions.clear());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final s in toDispose) {
        s.dispose();
      }
    });
  }

  @override
  void dispose() {
    for (final s in _sessions) {
      s.removeListener(_onSessionUpdate);
      s.dispose();
    }
    _sessions.clear();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final local = _canUseLocalTerminal;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Terminal'),
        actions: [
          if (local)
            IconButton(
              icon: const Icon(Icons.computer),
              tooltip: 'Local terminal',
              onPressed: _busy ? null : () => _addSession(local: true),
            ),
          IconButton(
            icon: const Icon(Icons.cloud),
            tooltip: 'Remote terminal',
            onPressed: _busy ? null : () => _addSession(local: false),
          ),
          IconButton(
            icon: const Icon(Icons.close),
            tooltip: 'Close all',
            onPressed: _sessions.isEmpty ? null : _closeAll,
          ),
        ],
      ),
      body: TerminalGrid(
        sessions: _sessions,
        onClose: _removeSession,
      ),
    );
  }
}
