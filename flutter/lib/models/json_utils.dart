import 'dart:convert';

/// Decode a JSON body that may be either a raw string (error) or a JSON object.
Map<String, dynamic>? tryDecodeJson(String body) {
  try {
    final decoded = jsonDecode(body);
    if (decoded is Map<String, dynamic>) return decoded;
  } catch (_) {}
  return null;
}

/// Reduce a non-JSON HTTP error body to something safe to show verbatim:
/// HTML pages and proxy dumps collapse to [fallback], long payloads get
/// truncated, and short plain text passes through unchanged.
String sanitizeHttpErrorBody(String body, String fallback) {
  final trimmed = body.trim();
  if (trimmed.isEmpty) return fallback;
  if (trimmed.startsWith('<')) return fallback;
  if (trimmed.length > 300) return '${trimmed.substring(0, 300)}…';
  return trimmed;
}
