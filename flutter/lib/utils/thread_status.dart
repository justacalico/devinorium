import '../models/models.dart';

String? activeThreadTag({
  required bool sending,
  required List<Message> messages,
  required PermissionRequest? pendingPermissionRequest,
}) {
  if (pendingPermissionRequest != null) return 'needs approval';
  if (sending) return 'running';

  if (messages.isEmpty) return null;
  final last = messages.last;
  return switch (last.role) {
    'error' => 'failed',
    'user' => 'working',
    'assistant' => 'done',
    _ => null,
  };
}
