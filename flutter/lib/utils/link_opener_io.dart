import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

Future<void> openLinkImpl(String href) async {
  final uri = Uri.tryParse(href);
  if (uri == null) return;
  try {
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  } on PlatformException {
    if (Platform.isLinux) {
      await Process.run('xdg-open', [href]);
    } else {
      rethrow;
    }
  }
}
