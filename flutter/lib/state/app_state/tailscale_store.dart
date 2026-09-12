part of 'package:devinorium_frontend/state/app_state.dart';

mixin TailscaleStore on AppStateBase {
  @override
  TailscaleInfo? _tailscaleInfo;
  @override
  bool _tailscaleBusy = false;

  @override
  TailscaleInfo? get tailscaleInfo => _tailscaleInfo;
  @override
  bool get tailscaleBusy => _tailscaleBusy;

  /// Pull `GET /api/tailscale` for the active server. A missing endpoint
  /// (older server) just leaves the card hidden.
  @override
  Future<void> loadTailscaleStatus() async {
    if (multiServerState.activeApi == null) return;
    try {
      _tailscaleInfo = await api.tailscaleStatus();
    } catch (_) {
      _tailscaleInfo = null;
    }
    notifyListeners();
  }

  /// Flip the `tailscale serve` mapping. Returns an error string on failure.
  @override
  Future<String?> setTailscaleServe(bool enabled) async {
    if (_tailscaleBusy) return null;
    _tailscaleBusy = true;
    notifyListeners();
    try {
      _tailscaleInfo = await api.setTailscaleServe(enabled: enabled);
      return null;
    } on ApiException catch (e) {
      return e.message;
    } catch (e) {
      return '$e';
    } finally {
      _tailscaleBusy = false;
      notifyListeners();
    }
  }
}
