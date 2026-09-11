part of 'package:devinorium_frontend/state/app_state.dart';

mixin PlanOverlayStore on AppStateBase {
  @override
  bool _planOverlayVisible = false;
  @override
  bool _planOverlayExpanded = false;
  @override
  bool _planOverlayUserDismissed = false;
  @override
  bool get planOverlayVisible => _planOverlayVisible;
  @override
  bool get planOverlayExpanded => _planOverlayExpanded;
  @override
  bool get planOverlayDismissed => _planOverlayUserDismissed;
  @override
  Plan? get activePlan => _activeStore?.plan;
  @override
  Future<void> _loadPlanOverlayState() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      // The old key was written on every open/dismiss even when the user
      // never touched the expand state, so a stored `true` does not mean the
      // user chose expanded. Start over under a new key.
      await prefs.remove('devinorium_plan_overlay_expanded');
      _planOverlayExpanded =
          prefs.getBool('devinorium_plan_overlay_expanded_v2') ??
          _planOverlayExpanded;
      _planOverlayUserDismissed =
          prefs.getBool('devinorium_plan_overlay_dismissed') ?? false;
    } catch (_) {}
    notifyListeners();
  }
  @override
  Future<void> _savePlanOverlayState() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(
        'devinorium_plan_overlay_expanded_v2',
        _planOverlayExpanded,
      );
      await prefs.setBool(
        'devinorium_plan_overlay_dismissed',
        _planOverlayUserDismissed,
      );
    } catch (_) {}
  }
  @override
  void openPlanOverlay() {
    _planOverlayVisible = true;
    _planOverlayUserDismissed = false;
    notifyListeners();
    unawaited(_savePlanOverlayState());
  }
  @override
  void dismissPlanOverlay() {
    _planOverlayVisible = false;
    _planOverlayUserDismissed = true;
    notifyListeners();
    unawaited(_savePlanOverlayState());
  }
  @override
  void togglePlanOverlay() {
    if (_planOverlayVisible) {
      dismissPlanOverlay();
    } else {
      openPlanOverlay();
    }
  }
  @override
  void expandPlanOverlay() {
    _planOverlayVisible = true;
    _planOverlayExpanded = true;
    _planOverlayUserDismissed = false;
    notifyListeners();
    unawaited(_savePlanOverlayState());
  }
  @override
  void collapsePlanOverlay() {
    _planOverlayVisible = true;
    _planOverlayExpanded = false;
    _planOverlayUserDismissed = false;
    notifyListeners();
    unawaited(_savePlanOverlayState());
  }
  @override
  void togglePlanOverlayExpanded() {
    if (_planOverlayVisible) {
      _planOverlayExpanded = !_planOverlayExpanded;
    } else {
      openPlanOverlay();
    }
    notifyListeners();
    unawaited(_savePlanOverlayState());
  }
}
