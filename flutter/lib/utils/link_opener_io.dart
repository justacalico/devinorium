import 'package:url_launcher/url_launcher.dart';

Future<void> openLinkImpl(String href) async {
  final uri = Uri.tryParse(href);
  if (uri == null) return;
  await launchUrl(uri, mode: LaunchMode.externalApplication);
}
