import 'link_opener_io.dart' if (dart.library.js_interop) 'link_opener_web.dart';

/// Open [href] in the user's default browser.
///
/// Only http and https schemes are allowed.
Future<void> openLink(String href) async {
  final uri = Uri.tryParse(href);
  if (uri == null) return;
  if (uri.scheme != 'http' && uri.scheme != 'https') return;
  await openLinkImpl(href);
}

/// Whether [href] is a safe, openable URL.
bool isOpenableLink(String? href) {
  if (href == null || href.isEmpty) return false;
  final uri = Uri.tryParse(href);
  if (uri == null) return false;
  return uri.scheme == 'http' || uri.scheme == 'https';
}
