/// Exception thrown by the API client when a request fails.
///
/// The [message] is the human-readable backend error and [statusCode] is the
/// HTTP response code, when available.
class ApiException implements Exception {
  final String message;
  final int statusCode;
  ApiException(this.message, this.statusCode);

  @override
  String toString() => message;
}

/// A single parsed Server-Sent Events record.
class SseEvent {
  final String event;
  final String data;
  SseEvent(this.event, this.data);
}
