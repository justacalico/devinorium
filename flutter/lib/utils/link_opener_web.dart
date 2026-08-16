import 'package:web/web.dart' as web;

Future<void> openLinkImpl(String href) async {
  web.window.open(href, '_blank');
}
