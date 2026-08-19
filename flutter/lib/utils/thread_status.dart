import '../models/models.dart';

String? activeThreadTag({
  required bool sending,
  required List<Message> messages,
  required PermissionRequest? pendingPermissionRequest,
  AskRequest? pendingAskRequest,
  String? runStatus,
}) {
  if (pendingPermissionRequest != null) return 'needs approval';
  if (pendingAskRequest != null) return 'needs answer';
  if (sending) return 'running';
  if (runStatus == 'stopped') return 'stopped';
  if (runStatus == 'failed') return 'failed';
  if (runStatus == 'completed') return 'done';

  if (messages.isEmpty) return null;
  final last = messages.last;
  return switch (last.role) {
    'error' => 'failed',
    'user' => 'working',
    'assistant' => 'done',
    _ => null,
  };
}
