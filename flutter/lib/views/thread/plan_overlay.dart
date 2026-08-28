part of '../thread_page.dart';

/// The floating plan overlay at the top of the chat.
class _PlanOverlay extends StatelessWidget {
  const _PlanOverlay();

  @override
  Widget build(BuildContext context) {
    return Selector<AppState, _PlanOverlayModel>(
      selector: (_, state) => _PlanOverlayModel(
        plan: state.activePlan,
        expanded: state.planOverlayExpanded,
        dismissed: state.planOverlayDismissed,
      ),
      builder: (context, model, _) => PlanOverlay(
        plan: model.plan,
        expanded: model.expanded,
        dismissed: model.dismissed,
        onToggleExpand: () => context.read<AppState>().togglePlanOverlayExpanded(),
        onDismiss: () => context.read<AppState>().dismissPlanOverlay(),
      ),
    );
  }
}
