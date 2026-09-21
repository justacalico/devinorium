part of 'package:devinorium_frontend/state/app_state.dart';

/// Federation node selection: which satellite of the active hub the app's
/// data plane points at, or the hub itself when none is selected.
///
/// The hub connection never changes — a node switch only swaps the path
/// prefix requests carry (`/api/federation/nodes/<id>/proxy`), so all the
/// state reset rules of a server switch apply: threads, terminals, git
/// state, and composer selections belong to the previous target.
mixin NodeStore on AppStateBase {
  static const _nodeSelectionsKey = 'federation_node_selection';

  @override
  List<FederationNode> _federationNodes = [];
  @override
  String _federationSelfName = '';
  @override
  bool _federationSupported = false;
  @override
  String? _activeNodeId;
  @override
  int _federationSeq = 0;

  /// Remembered node id per server profile id, persisted so a returning
  /// user lands back on the satellite they were using.
  Map<String, String> _nodeSelections = {};
  bool _nodeSelectionsLoaded = false;

  @override
  List<FederationNode> get federationNodes => _federationNodes;
  @override
  String get federationSelfName => _federationSelfName;

  /// Whether the active hub answered the federation node list. Older
  /// servers have no federation routes; the selector stays hidden for them.
  @override
  bool get federationSupported => _federationSupported;

  @override
  String? get activeNodeId => _activeNodeId;

  /// The selected satellite, or null while the hub itself is the target.
  @override
  FederationNode? get activeNode {
    final id = _activeNodeId;
    if (id == null) return null;
    for (final n in _federationNodes) {
      if (n.id == id) return n;
    }
    return null;
  }

  /// The unprefixed service for the active hub. Federation management and
  /// auth calls must use this even while a node is selected: routing them
  /// through the proxy would land them on the satellite instead.
  @override
  ApiService get hubApi => multiServerState.activeApi ?? api;

  /// Pull the node list from the active hub. Runs against the unprefixed
  /// service on purpose so it keeps working while a satellite is selected
  /// (and is how a dead satellite's offline flag reaches the UI).
  @override
  Future<void> refreshFederationNodes() async {
    final serverId = multiServerState.activeServerId;
    final service = multiServerState.activeApi;
    if (serverId == null || service == null) return;
    // The node list is owner-only; skip the request entirely once a signed
    // in non-owner is known rather than logging a 403 every health tick.
    final user = _user;
    if (user != null && !user.isOwner) {
      // A non-owner can never hold a node selection (the picker is hidden
      // and the proxy is owner-only), but clear a stale one defensively so
      // a downgraded account is not left bound to a route that always 403s.
      if (_activeNodeId != null) {
        _activeNodeId = null;
        unawaited(_persistNodeSelection());
      }
      if (_federationSupported || _federationNodes.isNotEmpty) {
        _federationSupported = false;
        _federationNodes = [];
        _federationSelfName = '';
        notifyListeners();
      }
      return;
    }
    final seq = ++_federationSeq;
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
      final active = _activeNodeId;
      if (active != null && !res.nodes.any((n) => n.id == active)) {
        // The selected satellite was deregistered. During a server switch
        // or bootstrap the in-progress load just needs the binding dropped;
        // mid-session the loaded data came from the vanished node, so fall
        // back to the hub with a full reset.
        if (_switchingServer || _user == null) {
          _activeNodeId = null;
          unawaited(_persistNodeSelection());
          notifyListeners();
        } else {
          unawaited(switchNode(null));
        }
      }
    } on ApiException catch (e) {
      // Non-owners cannot list nodes and older servers have no federation
      // routes; either way the section stays hidden.
      if (seq != _federationSeq) return;
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

  /// Re-target the app at a satellite of the active hub, or back at the hub
  /// itself when [nodeId] is null. Mirrors [switchServer].
  @override
  Future<void> switchNode(String? nodeId) async {
    if (_switchingServer || nodeId == _activeNodeId) return;
    _switchingServer = true;
    stopHealthChecks();
    stopGitRefresh();
    try {
      // Terminals belong to the previous target — kill them while the api
      // getter still resolves to it.
      await terminalStore.clear();
      _activeNodeId = nodeId;
      await _persistNodeSelection();
      await _resetServerState();
      unawaited(loadTailscaleStatus());
      await _loadUserAndData();
    } catch (e) {
      _globalError = '$e';
      notifyListeners();
    } finally {
      _switchingServer = false;
    }
  }

  /// Deregister a satellite from the active hub (owner only). Returns an
  /// error string on failure. Removing the selected node first falls back
  /// to the hub so nothing is left bound to a dead proxy route.
  @override
  Future<String?> removeFederationNode(String nodeId) async {
    try {
      if (_activeNodeId == nodeId) {
        await switchNode(null);
      }
      await hubApi.removeFederationNode(nodeId);
      await refreshFederationNodes();
      return null;
    } on ApiException catch (e) {
      return e.message;
    } catch (e) {
      return '$e';
    }
  }

  /// Restore the remembered node for the active server. Runs after server
  /// switches and at bootstrap, before the data load, so `api` resolves to
  /// the right target for `me()` and everything after it.
  @override
  Future<void> restoreNodeSelection() async {
    final serverId = multiServerState.activeServerId;
    if (serverId == null) return;
    await _loadNodeSelections();
    _activeNodeId = _nodeSelections[serverId];
  }

  /// Forget the stored node for a removed server profile.
  @override
  void dropNodeSelectionFor(String serverId) {
    if (_nodeSelections.remove(serverId) != null) {
      unawaited(_saveNodeSelections());
    }
  }

  Future<void> _loadNodeSelections() async {
    if (_nodeSelectionsLoaded) return;
    _nodeSelectionsLoaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_nodeSelectionsKey);
      final decoded = raw == null ? null : jsonDecode(raw);
      if (decoded is Map) {
        _nodeSelections = {
          for (final e in decoded.entries) '${e.key}': '${e.value}',
        };
      }
    } catch (_) {}
  }

  Future<void> _persistNodeSelection() async {
    final serverId = multiServerState.activeServerId;
    if (serverId == null) return;
    await _loadNodeSelections();
    final nodeId = _activeNodeId;
    if (nodeId == null) {
      _nodeSelections.remove(serverId);
    } else {
      _nodeSelections[serverId] = nodeId;
    }
    await _saveNodeSelections();
  }

  Future<void> _saveNodeSelections() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_nodeSelectionsKey, jsonEncode(_nodeSelections));
    } catch (_) {}
  }
}
