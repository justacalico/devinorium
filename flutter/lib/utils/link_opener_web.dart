import 'package:web/web.dart' as web;

Future<void> openLinkImpl(String href) async {
  final window = web.window.open(href, '_blank');
  if (window == null) throw StateError('Could not open $href');
}
