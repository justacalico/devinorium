import 'dart:convert';

/// Decode a JSON body that may be either a raw string (error) or a JSON object.
Map<String, dynamic>? tryDecodeJson(String body) {
  try {
    final decoded = jsonDecode(body);
    if (decoded is Map<String, dynamic>) return decoded;
  } catch (_) {}
  return null;
}
