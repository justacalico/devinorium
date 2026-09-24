import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../models/models.dart';
import '../utils/file_size.dart';
import '../utils/image_size.dart';

/// Displays a binary image file inline. The files API always returns the raw
/// bytes as base64, so no extra request is needed. The image can be panned and
/// zoomed; undecodable payloads fall back to a placeholder.
class ImageFileView extends StatefulWidget {
  final FileContent content;

  const ImageFileView({super.key, required this.content});

  @override
  State<ImageFileView> createState() => _ImageFileViewState();
}

class _ImageFileViewState extends State<ImageFileView> {
  /// Decode ceiling so a small but hostile image cannot allocate gigabytes of
  /// pixels. Larger images are downscaled to fit while keeping aspect ratio.
  static const _maxDecodeDim = 4096;

  final _transformationController = TransformationController();
  ImageProvider? _provider;
  (int, int)? _dimensions;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(ImageFileView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.content.base64 != widget.content.base64) {
      _load();
    }
  }

  @override
  void dispose() {
    _transformationController.dispose();
    super.dispose();
  }

  void _load() {
    Uint8List? bytes;
    try {
      final decoded = base64Decode(widget.content.base64);
      if (decoded.isNotEmpty) bytes = decoded;
    } on FormatException {
      // Not a decodable payload; the placeholder is shown.
    }
    _dimensions = bytes == null ? null : intrinsicImageSize(bytes);
    _provider = bytes == null
        ? null
        : ResizeImage(
            MemoryImage(bytes),
            policy: ResizeImagePolicy.fit,
            width: _maxDecodeDim,
            height: _maxDecodeDim,
          );
    _transformationController.value = Matrix4.identity();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l = l10n(context);
    final provider = _provider;
    final dimensions = _dimensions;

    final details = StringBuffer()
      ..write(widget.content.mime)
      ..write(' • ')
      ..write(formatFileSize(widget.content.size, l));
    if (dimensions != null) {
      details.write(' • ${dimensions.$1}×${dimensions.$2}');
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              details.toString(),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: provider == null
              ? _BrokenImage(color: theme.colorScheme.onSurfaceVariant)
              : InteractiveViewer(
                  transformationController: _transformationController,
                  trackpadScrollCausesScale: true,
                  maxScale: 20,
                  child: Center(
                    child: Image(
                      image: provider,
                      fit: BoxFit.contain,
                      gaplessPlayback: true,
                      semanticLabel: widget.content.path,
                      errorBuilder: (context, error, stackTrace) =>
                          _BrokenImage(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                    ),
                  ),
                ),
        ),
      ],
    );
  }
}

class _BrokenImage extends StatelessWidget {
  final Color color;

  const _BrokenImage({required this.color});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Icon(Icons.broken_image_outlined, size: 48, color: color),
    );
  }
}
