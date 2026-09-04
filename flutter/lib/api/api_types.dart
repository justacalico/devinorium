/// Exception thrown by the API client when a request fails.
///
/// The [message] is the human-readable backend error and [statusCode] is the
/// HTTP response code, when available. [data] holds the parsed response body
/// for structured errors such as a 409 file conflict.
class ApiException implements Exception {
  final String message;
  final int statusCode;
  final Map<String, dynamic>? data;
  ApiException(this.message, this.statusCode, {this.data});

  @override
  String toString() => message;
}

/// A single parsed Server-Sent Events record.
class SseEvent {
  final String event;
  final String data;
  final String? id;
  SseEvent(this.event, this.data, {this.id});
}
