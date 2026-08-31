import 'package:flutter/foundation.dart';

/// Logs a failure to the console in debug builds only.
///
/// Production and profile builds compile this to a no-op, so internal error
/// details (exception messages, thread ids, etc.) never leak into release
/// logs. Use this anywhere a thread operation fails so the failure is
/// diagnosable locally without surfacing internals to end users.
void debugLogFailure(String context, Object? error, {String? threadId}) {
  if (!kDebugMode) return;
  final id = threadId == null ? '' : ' thread=$threadId';
  debugPrint('[devinorium] $context failed$id: $error');
}
