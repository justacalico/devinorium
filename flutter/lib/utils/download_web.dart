import 'dart:js_interop';

import 'package:web/web.dart' as web;

Future<void> downloadImpl(String content, String filename) async {
  final blob = web.Blob(
    [content.toJS].toJS,
    web.BlobPropertyBag(type: 'application/json'),
  );
  final url = web.URL.createObjectURL(blob);
  final a = web.HTMLAnchorElement();
  a.href = url;
  a.download = filename;
  a.click();
  web.URL.revokeObjectURL(url);
}
