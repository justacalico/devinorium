import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';

@visibleForTesting
Future<ProcessResult> Function(String, List<String>)? xdgOpenRunnerOverride;

Future<void> openLinkImpl(
  String href, {
  Future<ProcessResult> Function(String, List<String>)? runProcess,
}) async {
  final uri = Uri.tryParse(href);
  if (uri == null) return;
  var needsFallback = false;
  try {
    needsFallback = !await launchUrl(uri, mode: LaunchMode.externalApplication);
  } on Exception {
    needsFallback = true;
  }
  if (!needsFallback) return;
  if (Platform.isLinux) {
    try {
      final run = runProcess ?? xdgOpenRunnerOverride ?? Process.run;
      final result = await run('xdg-open', [href]);
      if (result.exitCode == 0) return;
    } on Exception {
      // xdg-open missing or failed; the StateError below reports it.
    }
  }
  throw StateError('Could not open $href');
}
