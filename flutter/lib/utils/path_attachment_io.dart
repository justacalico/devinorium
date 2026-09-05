import 'dart:io';

import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;

import 'path_attachment_types.dart';

const _maxSize = 8 * 1024 * 1024;

bool _hasParentReference(String path) {
  return path.replaceAll('\\', '/').split('/').contains('..');
}

Future<PathAttachmentResult> attachPath(String text) async {
  final trimmed = text.trim();
  if (trimmed.isEmpty || trimmed.contains('\n')) {
    return const PathFallback();
  }

  String? path;

  if (trimmed.startsWith('file://')) {
    try {
      final normalized = trimmed.startsWith('file:///')
          ? trimmed
          : trimmed.replaceFirst(
              RegExp(r'^file://([A-Za-z]:)'),
              r'file:///$1',
            );
      final uri = Uri.parse(normalized);
      if (uri.scheme == 'file') {
        path = uri.toFilePath();
      }
    } on FormatException {
      // fallthrough to fallback
    }
  } else if (RegExp(r'^[A-Za-z]:[\\/]').hasMatch(trimmed) ||
      trimmed.startsWith(r'\\') ||
      trimmed.startsWith('/')) {
    path = trimmed;
  }

  if (path == null || path.isEmpty || _hasParentReference(path)) {
    return const PathFallback();
  }

  // Canonicalize to collapse redundant separators, then use the platform style.
  path = p.canonicalize(path);

  try {
    final file = File(path);
    final exists = await file.exists();
    if (!exists) return const PathFallback();

    final type = await FileSystemEntity.type(path);
    if (type != FileSystemEntityType.file) return const PathFallback();

    final bytes = await file.readAsBytes();
    if (bytes.length > _maxSize) {
      return PathTooLarge(p.basename(path), bytes.length);
    }

    final filename = p.basename(path);
    final mime = lookupMimeType(filename) ?? 'application/octet-stream';

    return PathAttached(filename, mime, bytes);
  } on FileSystemException {
    return const PathFallback();
  } catch (_) {
    return const PathFallback();
  }
}
