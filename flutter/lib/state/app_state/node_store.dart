part of 'package:devinorium_frontend/state/app_state.dart';

/// Satellite nodes paired with the active hub. A node is an execution
/// target: projects bound to it run their agents, files, git and terminals
/// on that machine through the hub's `/api/node` protocol. There is no
/// node switching — the app always talks to the hub.
mixin NodeStore on AppStateBase {
  @override
  List<FederationNode> _federationNodes = [];
  @override
  String _federationSelfName = '';
  @override
  bool _federationSupported = false;
  @override
  int _federationSeq = 0;

  @override
  List<FederationNode> get federationNodes => _federationNodes;
  @override
  String get federationSelfName => _federationSelfName;

  /// Whether the active hub answered the federation node list. Older
  /// servers have no federation routes; the section stays hidden for them.
  @override
  bool get federationSupported => _federationSupported;

  /// The unprefixed service for the active hub. Kept as an alias so
  /// auth and admin calls read clearly at call sites — there is no
  /// node-bound service to distinguish it from anymore.
  @override
  ApiService get hubApi => multiServerState.activeApi ?? api;

  /// Pull the node list from the active hub.
  @override
  Future<void> refreshFederationNodes() async {
    final serverId = multiServerState.activeServerId;
    final service = multiServerState.activeApi;
    if (serverId == null || service == null) return;
    final seq = ++_federationSeq;
    // The node list is owner-only; skip the request entirely once a signed
    // in non-owner is known rather than logging a 403 every health tick.
    final user = _user;
    if (user != null && !user.isOwner) {
      if (_federationSupported || _federationNodes.isNotEmpty) {
        _federationSupported = false;
        _federationNodes = [];
        _federationSelfName = '';
        notifyListeners();
      }
      return;
    }
    try {
      final res = await service.federationNodes();
      if (seq != _federationSeq ||
          multiServerState.activeServerId != serverId) {
        return;
      }
      _federationSupported = true;
      _federationSelfName = res.selfName;
      _federationNodes = res.nodes;
      notifyListeners();
    } on ApiException catch (e) {
      // Non-owners cannot list nodes and older servers have no federation
      // routes; either way the section stays hidden.
      if (seq != _federationSeq ||
          multiServerState.activeServerId != serverId) {
        return;
      }
      if (e.statusCode == 403 || e.statusCode == 404) {
        _federationSupported = false;
        _federationNodes = [];
        _federationSelfName = '';
        notifyListeners();
      }
    } catch (_) {
      // Keep the last known list on transport errors.
    }
  }

  /// Pair a satellite against the active hub with its printed pairing
  /// code, then refresh the list. Returns an error string on failure.
  @override
  Future<String?> pairFederationNode({
    required String url,
    required String code,
    String? name,
  }) async {
    try {
      await hubApi.pairFederationNode(url: url, code: code, name: name);
      await refreshFederationNodes();
      return null;
    } on ApiException catch (e) {
      return e.message;
    } catch (e) {
      return '$e';
    }
  }

  /// Deregister a satellite from the active hub (owner only). Returns an
  /// error string on failure.
  @override
  Future<String?> removeFederationNode(String nodeId) async {
    try {
      await hubApi.removeFederationNode(nodeId);
      await refreshFederationNodes();
      return null;
    } on ApiException catch (e) {
      return e.message;
    } catch (e) {
      return '$e';
    }
  }

  /// The node id of the active project, when it lives on a satellite.
  /// Used for node-scoped calls like listing models on that machine.
  @override
  String? get _activeProjectNodeId {
    final id = _activeProjectId;
    if (id == null) return null;
    for (final p in _projects) {
      if (p.id == id) return p.nodeId;
    }
    return null;
  }
}
