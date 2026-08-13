import 'download_io.dart' if (dart.library.js_interop) 'download_web.dart';

/// Save [content] as a file named [filename]. On web this triggers a browser
/// download; on native it opens a save-file dialog.
Future<void> downloadTextFile(String content, String filename) async {
  await downloadImpl(content, filename);
}
