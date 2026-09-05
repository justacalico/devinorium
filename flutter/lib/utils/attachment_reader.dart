import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:mime/mime.dart';

const _defaultMaxAttachmentSize = 8 * 1024 * 1024;
const _mimeHeaderBytes = 8192;

typedef FileAttachment = ({
  String filename,
  String mime,
  Uint8List bytes,
});

sealed class AttachmentResult {
  const AttachmentResult();
}

final class AttachmentSuccess extends AttachmentResult {
  final FileAttachment attachment;
  const AttachmentSuccess(this.attachment);
}

final class AttachmentTooLarge extends AttachmentResult {
  final String filename;
  final int size;
  const AttachmentTooLarge(this.filename, this.size);
}

final class AttachmentReadError extends AttachmentResult {
  final String filename;
  final Object error;
  const AttachmentReadError(this.filename, this.error);
}

abstract class AttachmentSource {
  String get name;
  Future<int> length();
  Future<Uint8List> readAsBytes();
  String? get mimeType;
}

class InMemoryAttachmentSource implements AttachmentSource {
  final String filename;
  final Uint8List bytes;
  final String? mime;

  const InMemoryAttachmentSource(this.filename, this.bytes, {this.mime});

  @override
  String get name => filename;

  @override
  String? get mimeType => mime;

  @override
  Future<int> length() => Future.value(bytes.length);

  @override
  Future<Uint8List> readAsBytes() => Future.value(bytes);
}

Future<AttachmentResult> readAttachment(
  AttachmentSource source, {
  int maxSize = _defaultMaxAttachmentSize,
}) async {
  try {
    final size = await source.length();
    if (size > maxSize) {
      return AttachmentTooLarge(source.name, size);
    }

    final bytes = await source.readAsBytes();
    if (bytes.length > maxSize) {
      return AttachmentTooLarge(source.name, bytes.length);
    }

    final header = bytes.sublist(
      0,
      min(_mimeHeaderBytes, bytes.length),
    );
    final sourceMime = source.mimeType?.isNotEmpty == true ? source.mimeType : null;
    final mime = sourceMime ??
        lookupMimeType(source.name, headerBytes: header) ??
        'application/octet-stream';

    return AttachmentSuccess((
      filename: source.name,
      mime: mime,
      bytes: bytes,
    ));
  } catch (e) {
    return AttachmentReadError(source.name, e);
  }
}
