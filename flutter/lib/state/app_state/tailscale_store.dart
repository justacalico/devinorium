part of 'package:devinorium_frontend/state/app_state.dart';

mixin TailscaleStore on AppStateBase {
  @override
  TailscaleInfo? _tailscaleInfo;
  @override
  bool _tailscaleBusy = false;
  @override
  int _tailscaleSeq = 0;

  @override
  TailscaleInfo? get tailscaleInfo => _tailscaleInfo;
  @override
  bool get tailscaleBusy => _tailscaleBusy;

  /// Pull `GET /api/tailscale` for the active server. A missing endpoint
  /// (older server) just leaves the card hidden. The seq guard keeps a
  /// response from the previous server from landing after a switch.
  @override
  Future<void> loadTailscaleStatus() async {
    if (multiServerState.activeApi == null) return;
    final seq = _tailscaleSeq;
    try {
      final info = await api.tailscaleStatus();
      if (seq != _tailscaleSeq) return;
      _tailscaleInfo = info;
    } catch (_) {
      if (seq != _tailscaleSeq) return;
      _tailscaleInfo = null;
    }
    notifyListeners();
  }

  /// Flip the `tailscale serve` mapping; `port` chooses the tailnet HTTPS
  /// port when enabling and is persisted by the server. Returns an error
  /// string on failure.
  @override
  Future<String?> setTailscaleServe(bool enabled, {int? port}) async {
    if (_tailscaleBusy) return null;
    final seq = _tailscaleSeq;
    _tailscaleBusy = true;
    notifyListeners();
    try {
      final info = await api.setTailscaleServe(enabled: enabled, port: port);
      if (seq == _tailscaleSeq) _tailscaleInfo = info;
      return null;
    } on ApiException catch (e) {
      return seq != _tailscaleSeq ? null : e.message;
    } catch (e) {
      return seq != _tailscaleSeq ? null : '$e';
    } finally {
      if (seq == _tailscaleSeq) _tailscaleBusy = false;
      notifyListeners();
    }
  }
}
