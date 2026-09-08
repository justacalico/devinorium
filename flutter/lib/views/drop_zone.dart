import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_dropzone/flutter_dropzone.dart';
import 'package:image_picker/image_picker.dart' show XFile;
import 'package:provider/provider.dart';

import '../l10n/l10n.dart';
import '../state/app_state.dart';
import '../utils/attachment_reader.dart';
import '../utils/media_picker.dart';
import 'attachment_source_sheet.dart';

class DropZone extends StatefulWidget {
  final Widget child;

  /// Overrides the media picker used on mobile. For tests.
  final MediaPicker? mediaPicker;

  const DropZone({super.key, required this.child, this.mediaPicker});

  static DropZoneController? of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<_DropZoneScope>();
    return scope?.controller;
  }

  @override
  State<DropZone> createState() => _DropZoneState();
}

class DropZoneController {
  final Future<List<FileAttachment>> Function({required bool multiple}) pick;
  DropZoneController({required this.pick});
}

class _DropZoneScope extends InheritedWidget {
  final DropZoneController controller;
  const _DropZoneScope({required this.controller, required super.child});

  @override
  bool updateShouldNotify(_DropZoneScope old) => old.controller != controller;
}

class _DropZoneState extends State<DropZone> {
  DropzoneViewController? _webCtrl;
  bool _hovering = false;
  late final DropZoneController _controller;
  final _defaultMediaPicker = ImagePickerMediaPicker();

  MediaPicker get _mediaPicker =>
      widget.mediaPicker ?? _defaultMediaPicker;

  static const _maxSize = 8 * 1024 * 1024;

  @override
  void initState() {
    super.initState();
    _controller = DropZoneController(pick: _pickFiles);
  }

  Future<List<FileAttachment>> _pickFiles({required bool multiple}) async {
    if (kIsWeb) return _pickWebFiles(multiple: multiple);
    if (_isMobile(context)) return _pickMobileFiles(multiple: multiple);
    return _pickNativeFiles(multiple: multiple);
  }

  bool _isMobile(BuildContext context) {
    return switch (Theme.of(context).platform) {
      TargetPlatform.iOS || TargetPlatform.android => true,
      _ => false,
    };
  }

  Future<List<FileAttachment>> _pickMobileFiles({
    required bool multiple,
  }) async {
    try {
      final source = await showAttachSourceSheet(context);
      if (!mounted || source == null) return [];
      switch (source) {
        case AttachSource.browse:
          return _pickNativeFiles(multiple: multiple);
        case AttachSource.photoLibrary:
          final files = await _mediaPicker.pickGalleryMedia(
            multiple: multiple,
          );
          return _readMediaFiles(files);
        case AttachSource.camera:
          final mode = await showCameraCaptureSheet(context);
          if (!mounted || mode == null) return [];
          final file = switch (mode) {
            CameraCapture.photo => await _mediaPicker.capturePhoto(),
            CameraCapture.video => await _mediaPicker.captureVideo(),
          };
          if (file == null) return [];
          return _readMediaFiles([file]);
      }
    } catch (e) {
      if (mounted) {
        context
            .read<AppState>()
            .setGlobalError(l10n(context).dropZonePickFilesFailed('$e'));
      }
      return [];
    }
  }

  Future<List<FileAttachment>> _readMediaFiles(List<XFile> files) async {
    if (files.isEmpty) return [];
    final results = await Future.wait(
      files.map((f) => readAttachment(_XFileSource(f), maxSize: _maxSize)),
    );
    return _collect(results);
  }

  Future<List<FileAttachment>> _pickWebFiles({required bool multiple}) async {
    if (_webCtrl == null) return [];
    try {
      final files = await _webCtrl!.pickFiles(multiple: multiple);
      final results = await Future.wait(
        files.map((f) => _readWebFile(f)),
      );
      return _collect(results);
    } catch (e) {
      if (mounted) {
        context
            .read<AppState>()
            .setGlobalError(l10n(context).dropZonePickFilesFailed('$e'));
      }
      return [];
    }
  }

  Future<List<FileAttachment>> _pickNativeFiles({
    required bool multiple,
  }) async {
    try {
      final List<PlatformFile> files;
      const windowsOptions = WindowsOptions(lockParentWindow: true);
      const linuxOptions = LinuxOptions(lockParentWindow: true);
      if (multiple) {
        files = await FilePicker.pickFiles(
          windowsOptions: windowsOptions,
          linuxOptions: linuxOptions,
        );
      } else {
        final file = await FilePicker.pickFile(
          windowsOptions: windowsOptions,
          linuxOptions: linuxOptions,
        );
        files = file != null ? [file] : [];
      }
      if (files.isEmpty) return [];
      final results = await Future.wait(
        files.map((f) => readAttachment(_PlatformFileSource(f), maxSize: _maxSize)),
      );
      return _collect(results);
    } catch (e) {
      if (mounted) {
        context
            .read<AppState>()
            .setGlobalError(l10n(context).dropZonePickFilesFailed('$e'));
      }
      return [];
    }
  }

  Future<AttachmentResult> _readWebFile(DropzoneFileInterface file) async {
    final name = await _webCtrl!.getFilename(file);
    final mime = await _webCtrl!.getFileMIME(file);
    final size = await _webCtrl!.getFileSize(file);
    return readAttachment(
      _WebAttachmentSource(
        controller: _webCtrl!,
        file: file,
        filename: name,
        mime: mime,
        size: size,
      ),
      maxSize: _maxSize,
    );
  }

  Future<List<FileAttachment>> _collect(List<AttachmentResult> results) async {
    if (!mounted) return [];
    final attachments = <FileAttachment>[];
    final errors = <String>[];
    for (final result in results) {
      switch (result) {
        case AttachmentSuccess():
          attachments.add(result.attachment);
        case AttachmentTooLarge():
          errors.add(l10n(context).dropZoneFileTooLarge(result.filename));
        case AttachmentReadError():
          errors.add(l10n(context).dropZoneReadFileFailed('${result.error}'));
      }
    }
    if (errors.isNotEmpty && mounted) {
      context.read<AppState>().setGlobalError(errors.join('\n'));
    }
    return attachments;
  }

  Future<void> _handleWebDrop(List<DropzoneFileInterface>? files) async {
    if (files == null || files.isEmpty) {
      if (mounted) setState(() => _hovering = false);
      return;
    }
    try {
      final results = await Future.wait(files.map(_readWebFile));
      final attachments = await _collect(results);
      if (attachments.isNotEmpty && mounted) {
        context.read<AppState>().addAttachments(attachments);
      }
    } catch (e) {
      if (mounted) {
        context
            .read<AppState>()
            .setGlobalError(l10n(context).dropZoneAttachFilesFailed('$e'));
      }
    }
    if (mounted) setState(() => _hovering = false);
  }

  Future<void> _handleDesktopDrop(DropDoneDetails detail) async {
    final results = <AttachmentResult>[];
    for (final item in detail.files) {
      if (item is DropItemDirectory) continue;
      results.add(
        await readAttachment(
          _DropItemSource(item),
          maxSize: _maxSize,
        ),
      );
    }
    try {
      final attachments = await _collect(results);
      if (attachments.isNotEmpty && mounted) {
        context.read<AppState>().addAttachments(attachments);
      }
    } catch (e) {
      if (mounted) {
        context
            .read<AppState>()
            .setGlobalError(l10n(context).dropZoneAttachFilesFailed('$e'));
      }
    }
    if (mounted) setState(() => _hovering = false);
  }

  @override
  Widget build(BuildContext context) {
    return _DropZoneScope(
      controller: _controller,
      child: kIsWeb ? _buildWeb() : _buildForPlatform(context),
    );
  }

  bool _isDesktop(BuildContext context) {
    return switch (Theme.of(context).platform) {
      TargetPlatform.linux ||
      TargetPlatform.macOS ||
      TargetPlatform.windows =>
        true,
      _ => false,
    };
  }

  Widget _buildForPlatform(BuildContext context) {
    if (_isDesktop(context)) {
      return _buildDesktop();
    }
    return widget.child;
  }

  Widget _buildWeb() {
    return Stack(
      fit: StackFit.expand,
      children: [
        DropzoneView(
          operation: DragOperation.copy,
          onCreated: (c) => _webCtrl = c,
          onHover: () => setState(() => _hovering = true),
          onLeave: () => setState(() => _hovering = false),
          onDropFile: (file) => _handleWebDrop([file]),
          onDropFiles: (fs) => _handleWebDrop(fs),
          onError: (err) {
            if (mounted) {
              context
                  .read<AppState>()
                  .setGlobalError(l10n(context).dropZoneAttachFilesFailed(err ?? ''));
            }
          },
        ),
        widget.child,
        if (_hovering) const _DropOverlay(),
      ],
    );
  }

  Widget _buildDesktop() {
    return DropTarget(
      onDragEntered: (_) => setState(() => _hovering = true),
      onDragExited: (_) => setState(() => _hovering = false),
      onDragDone: (detail) => _handleDesktopDrop(detail),
      child: Stack(
        fit: StackFit.expand,
        children: [
          widget.child,
          if (_hovering) const _DropOverlay(),
        ],
      ),
    );
  }
}

class _WebAttachmentSource implements AttachmentSource {
  final DropzoneViewController controller;
  final DropzoneFileInterface file;

  @override
  final String name;

  final String? mime;
  final int size;

  _WebAttachmentSource({
    required this.controller,
    required this.file,
    required this.filename,
    required this.mime,
    required this.size,
  }) : name = filename;

  final String filename;

  @override
  String? get mimeType => mime?.isNotEmpty == true ? mime : null;

  @override
  Future<int> length() => Future.value(size);

  @override
  Future<Uint8List> readAsBytes() => controller.getFileData(file);
}

class _XFileSource implements AttachmentSource {
  final XFile file;

  _XFileSource(this.file);

  @override
  String get name => file.name;

  @override
  String? get mimeType =>
      file.mimeType?.isNotEmpty == true ? file.mimeType : null;

  @override
  Future<int> length() => file.length();

  @override
  Future<Uint8List> readAsBytes() => file.readAsBytes();
}

class _PlatformFileSource implements AttachmentSource {
  final PlatformFile file;

  _PlatformFileSource(this.file);

  @override
  String get name => file.name;

  @override
  String? get mimeType => null;

  @override
  Future<int> length() => file.length();

  @override
  Future<Uint8List> readAsBytes() => file.readAsBytes();
}

class _DropItemSource implements AttachmentSource {
  final DropItem item;

  _DropItemSource(this.item);

  @override
  String get name => item.name;

  @override
  String? get mimeType =>
      item.mimeType?.isNotEmpty == true ? item.mimeType : null;

  @override
  Future<int> length() => item.length();

  @override
  Future<Uint8List> readAsBytes() async {
    final bookmark = item.extraAppleBookmark;
    if (bookmark != null && bookmark.isNotEmpty) {
      final ok = await DesktopDrop.instance
          .startAccessingSecurityScopedResource(bookmark: bookmark);
      try {
        return await item.readAsBytes();
      } finally {
        if (ok) {
          await DesktopDrop.instance
              .stopAccessingSecurityScopedResource(bookmark: bookmark);
        }
      }
    }
    return item.readAsBytes();
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
              l10n(context).dropZoneDropHere,
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
