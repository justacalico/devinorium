import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_dropzone/flutter_dropzone.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';

typedef Attachment = ({String filename, String mime, Uint8List bytes});

class DropZone extends StatefulWidget {
  final Widget child;
  const DropZone({super.key, required this.child});

  static DropZoneController? of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<_DropZoneScope>();
    return scope?.controller;
  }

  @override
  State<DropZone> createState() => _DropZoneState();
}

class DropZoneController {
  final Future<List<Attachment>> Function({required bool multiple}) pick;
  DropZoneController({required this.pick});
}

class _DropZoneScope extends InheritedWidget {
  final DropZoneController controller;
  const _DropZoneScope({required this.controller, required super.child});

  @override
  bool updateShouldNotify(_DropZoneScope old) => old.controller != controller;
}

class _DropZoneState extends State<DropZone> {
  DropzoneViewController? _ctrl;
  bool _hovering = false;

  static const _maxSize = 8 * 1024 * 1024;

  Future<List<Attachment>> _processFiles(List<DropzoneFileInterface> files) async {
    if (_ctrl == null) return [];
    final attachments = <Attachment>[];
    final errors = <String>[];
    for (final f in files) {
      try {
        final name = await _ctrl!.getFilename(f);
        final mime = await _ctrl!.getFileMIME(f);
        final size = await _ctrl!.getFileSize(f);
        if (size > _maxSize) {
          errors.add('$name is too large (max 8 MB)');
          continue;
        }
        final bytes = await _ctrl!.getFileData(f);
        attachments.add((filename: name, mime: mime, bytes: bytes));
      } catch (e) {
        errors.add('Failed to read file: $e');
      }
    }
    if (errors.isNotEmpty && mounted) {
      final appState = context.read<AppState>();
      appState.setGlobalError(errors.join('\n'));
    }
    return attachments;
  }

  Future<void> _handleFiles(List<DropzoneFileInterface>? files) async {
    if (files == null || files.isEmpty) {
      if (mounted) setState(() => _hovering = false);
      return;
    }
    try {
      final attachments = await _processFiles(files);
      if (attachments.isNotEmpty && mounted) {
        final appState = context.read<AppState>();
        appState.addAttachments(attachments);
      }
    } catch (e) {
      if (mounted) {
        final appState = context.read<AppState>();
        appState.setGlobalError('Failed to attach files: $e');
      }
    }
    if (mounted) setState(() => _hovering = false);
  }

  Future<List<Attachment>> _pickFiles({required bool multiple}) async {
    if (_ctrl == null) return [];
    try {
      final files = await _ctrl!.pickFiles(multiple: multiple);
      return _processFiles(files);
    } catch (e) {
      if (mounted) {
        final appState = context.read<AppState>();
        appState.setGlobalError('Failed to pick files: $e');
      }
      return [];
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!kIsWeb) return widget.child;

    final controller = DropZoneController(pick: _pickFiles);

    return _DropZoneScope(
      controller: controller,
      child: Stack(
        fit: StackFit.expand,
        children: [
          DropzoneView(
            onCreated: (c) => _ctrl = c,
            onHover: () => setState(() => _hovering = true),
            onLeave: () => setState(() => _hovering = false),
            onDropFiles: (fs) => _handleFiles(fs),
          ),
          widget.child,
          if (_hovering) const _DropOverlay(),
        ],
      ),
    );
  }
}

class _DropOverlay extends StatelessWidget {
  const _DropOverlay();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      color: Colors.black.withValues(alpha: 0.5),
      alignment: Alignment.center,
      child: Container(
        margin: const EdgeInsets.all(32),
        padding: const EdgeInsets.all(32),
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: theme.colorScheme.primary,
            width: 2,
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.cloud_upload,
              size: 48,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(height: 16),
            Text(
              'Drop files here to attach',
              style: theme.textTheme.titleMedium?.copyWith(
                color: theme.colorScheme.onSurface,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
