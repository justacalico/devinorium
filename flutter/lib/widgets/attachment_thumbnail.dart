import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../l10n/l10n.dart';

/// Rounded tile that renders an image attachment instead of a filename chip.
/// The composer uses it for pending uploads and message history for sent
/// files once their bytes have been fetched.
class AttachmentThumb extends StatelessWidget {
  final Uint8List bytes;
  final String filename;
  final VoidCallback? onDelete;
  final VoidCallback? onTap;

  const AttachmentThumb({
    super.key,
    required this.bytes,
    required this.filename,
    this.onDelete,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Decode at tile resolution so multi-megapixel uploads do not allocate
    // full-size bitmaps for a 120x80 preview.
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return Container(
      width: 120,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 80,
            child: Stack(
              fit: StackFit.expand,
              children: [
                Image.memory(
                  bytes,
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                  cacheWidth: (120 * dpr).round(),
                  cacheHeight: (80 * dpr).round(),
                  errorBuilder: (context, error, stackTrace) => Center(
                    child: Icon(
                      Icons.broken_image_outlined,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                if (onTap != null)
                  Positioned.fill(
                    child: Material(
                      color: Colors.transparent,
                      child: InkWell(onTap: onTap),
                    ),
                  ),
                if (onDelete != null)
                  Positioned(
                    top: 4,
                    right: 4,
                    child: _DeleteButton(onPressed: onDelete!),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
            child: Text(
              filename,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall,
            ),
          ),
        ],
      ),
    );
  }
}

class _DeleteButton extends StatelessWidget {
  final VoidCallback onPressed;
  const _DeleteButton({required this.onPressed});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Tooltip(
      message: l10n(context).removeAttachment,
      child: Material(
        color: theme.colorScheme.surface.withValues(alpha: 0.85),
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onPressed,
          child: Padding(
            padding: const EdgeInsets.all(3),
            child: Icon(
              Icons.close,
              size: 14,
              color: theme.colorScheme.onSurface,
            ),
          ),
        ),
      ),
    );
  }
}

/// Open [bytes] in a zoomable dialog.
void showAttachmentPreview(
  BuildContext context, {
  required Uint8List bytes,
  required String filename,
}) {
  showDialog<void>(
    context: context,
    builder: (context) {
      final theme = Theme.of(context);
      return Dialog(
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 900, maxHeight: 700),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        filename,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall,
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close),
                      tooltip: l10n(context).close,
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
              ),
              Flexible(
                child: InteractiveViewer(
                  child: Center(child: Image.memory(bytes, fit: BoxFit.contain)),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}
