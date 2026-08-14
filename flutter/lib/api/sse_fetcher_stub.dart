import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../l10n/global_l10n.dart';
import 'api_types.dart';

Stream<SseEvent> platformFetchSseStream({
  required http.Client client,
  required String path,
  String method = 'POST',
  Map<String, String>? fields,
  List<({String filename, String mime, Uint8List bytes})>? attachments,
}) {
  return Stream.error(ApiException(appL10n.sseOnlySupportedOnWeb, 0));
}
