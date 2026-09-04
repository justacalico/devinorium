import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

Future<void> openLinkImpl(String href) async {
  final uri = Uri.tryParse(href);
  if (uri == null) return;
  try {
    final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!opened) throw StateError('Could not open $href');
  } on PlatformException {
    if (Platform.isLinux) {
      try {
        final result = await Process.run('xdg-open', [href]);
        if (result.exitCode != 0) {
          throw StateError('Could not open $href');
        }
      } on Exception {
        throw StateError('Could not open $href');
      }
    } else {
      rethrow;
    }
  }
}
