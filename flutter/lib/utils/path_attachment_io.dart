import 'dart:io';

import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;

import 'path_attachment_types.dart';

const _maxSize = 8 * 1024 * 1024;

Future<PathAttachmentResult> attachPath(String text) async {
  final trimmed = text.trim();
  if (trimmed.isEmpty || trimmed.contains('\n')) {
    return const PathFallback();
  }

  String? path;

  if (trimmed.startsWith('file://')) {
    try {
      final uri = Uri.parse(trimmed);
      if (uri.scheme == 'file') {
        path = uri.toFilePath();
      }
    } on FormatException {
      // fallthrough to fallback
    }
  } else if (RegExp(r'^[A-Za-z]:\\').hasMatch(trimmed) ||
      trimmed.startsWith(r'\\') ||
      trimmed.startsWith('/')) {
    path = trimmed;
  }

  if (path == null || path.isEmpty) {
    return const PathFallback();
  }

  final file = File(path);
  final exists = await file.exists();
  if (!exists) return const PathFallback();

  final type = await FileSystemEntity.type(path);
  if (type != FileSystemEntityType.file) return const PathFallback();

  final size = await file.length();
  if (size > _maxSize) {
    return PathTooLarge(p.basename(path), size);
  }

  final bytes = await file.readAsBytes();
  final filename = p.basename(path);
  final mime = lookupMimeType(filename) ?? 'application/octet-stream';

  return PathAttached(filename, mime, bytes);
}
