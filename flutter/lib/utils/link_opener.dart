import 'dart:async';

import 'link_opener_web.dart' if (dart.library.io) 'link_opener_io.dart';

/// Open [href] in the user's default browser.
///
/// Only http and https schemes are allowed.
Future<void> openLink(String href) {
  if (!isOpenableLink(href)) return Future.value();
  return openLinkImpl(href);
}

/// Whether [href] is a safe, openable URL.
bool isOpenableLink(String? href) {
  if (href == null || href.isEmpty) return false;
  final uri = Uri.tryParse(href);
  if (uri == null) return false;
  return uri.scheme == 'http' || uri.scheme == 'https';
}
