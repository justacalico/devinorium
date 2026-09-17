part of 'package:devinorium_frontend/state/app_state.dart';

/// Matches the backend `MAX_MACHINE_REFS` in machine_refs.rs.
const int maxMachineReferences = 8;

mixin MachineRefsStore on AppStateBase {
  // Same list-identity rule as attachments: the composer's Selector only
  // rebuilds when the list instance changes, so every mutation reassigns.
  @override
  List<MachineReference> _machineReferences = [];
  @override
  List<MachineReference> get machineReferences =>
      _activeStore?.machineReferences ?? _machineReferences;

  @override
  void addMachineReference(MachineReference ref) {
    final store = _activeStore;
    final current = store?.machineReferences ?? _machineReferences;
    if (current.any((r) => r.id == ref.id) ||
        current.length >= maxMachineReferences) {
      return;
    }
    final next = [...current, ref];
    if (store != null) {
      store.machineReferences = next;
    } else {
      _machineReferences = next;
    }
    notifyListeners();
  }

  @override
  void removeMachineReference(int index) {
    final store = _activeStore;
    if (store != null) {
      store.machineReferences = [...store.machineReferences]..removeAt(index);
    } else {
      _machineReferences = [..._machineReferences]..removeAt(index);
    }
    notifyListeners();
  }

  @override
  void clearMachineReferences() {
    final store = _activeStore;
    if (store != null) {
      store.machineReferences = [];
    } else {
      _machineReferences = [];
    }
    notifyListeners();
  }
}
