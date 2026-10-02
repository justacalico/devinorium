part of 'package:devinorium_frontend/state/app_state.dart';

/// Owner-managed MCP servers plus the per-thread skill list backing the
/// composer `/` picker.
mixin McpStore on AppStateBase {
  @override
  List<McpServerConfig> _mcpServers = [];
  @override
  int _mcpSeq = 0;

  @override
  List<McpServerConfig> get mcpServers => _mcpServers;

  /// Pull `GET /api/settings/mcp-servers` for the active server. Owner-only
  /// like machines: entries carry credentials in env/headers, so
  /// non-owners keep an empty list. The seq guard keeps a response from a
  /// previous server from landing after a switch.
  @override
  Future<void> loadMcpServers() async {
    if (multiServerState.activeApi == null || !isOwner) {
      // Bump the seq so an in-flight load from a previous server or role
      // cannot land, and drop a stale list — entries carry credentials.
      _mcpSeq++;
      if (_mcpServers.isNotEmpty) {
        _mcpServers = [];
        notifyListeners();
      }
      return;
    }
    final seq = ++_mcpSeq;
    try {
      final servers = await api.mcpServers();
      if (seq != _mcpSeq) return;
      _mcpServers = servers;
      notifyListeners();
    } catch (_) {
      // Keep a previously loaded list: one transient failure should not
      // empty the settings page.
    }
  }

  /// Replace the whole MCP server list; add/edit/delete/toggle all share
  /// this write. Returns an error string on failure.
  @override
  Future<String?> saveMcpServers(List<McpServerConfig> servers) async {
    try {
      _mcpServers = await api.saveMcpServers(servers);
      notifyListeners();
      return null;
    } on ApiException catch (e) {
      return e.message;
    } catch (e) {
      return '$e';
    }
  }

  // ---- Skills ----

  @override
  List<Skill> _skills = [];
  @override
  String? _skillsThreadId;
  @override
  int _skillsSeq = 0;

  /// Skills for the active thread; a stale list from another thread is
  /// never reported.
  @override
  List<Skill> get skills =>
      _skillsThreadId == activeThreadId ? _skills : const [];

  /// Pull `GET /api/threads/:id/skills` for the active thread. The picker
  /// calls this when it opens; a loaded non-empty list is reused until the
  /// thread changes, while an empty result refetches each open so a skill
  /// dropped into the project mid-session shows up.
  @override
  Future<void> loadSkills() async {
    final threadId = activeThreadId;
    if (multiServerState.activeApi == null || threadId == null) return;
    if (_skillsThreadId == threadId && _skills.isNotEmpty) return;
    final seq = ++_skillsSeq;
    if (_skillsThreadId != threadId) {
      // Drop the previous thread's list before the fetch so the getter
      // never reports it under the new thread.
      _skills = const [];
    }
    _skillsThreadId = threadId;
    try {
      final skills = await api.skills(threadId);
      if (seq != _skillsSeq) return;
      _skills = skills;
      notifyListeners();
    } catch (_) {
      // An old server without the endpoint or a transient failure leaves
      // the picker empty rather than crashing the composer.
      if (seq == _skillsSeq) {
        _skills = const [];
      }
    }
  }
}
