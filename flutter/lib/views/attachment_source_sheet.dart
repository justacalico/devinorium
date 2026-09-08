import 'package:flutter/cupertino.dart'
    show
        CupertinoActionSheet,
        CupertinoActionSheetAction,
        CupertinoIcons,
        showCupertinoModalPopup;
import 'package:flutter/material.dart';

import '../l10n/l10n.dart';

/// Where a mobile attachment comes from.
enum AttachSource { photoLibrary, camera, browse }

enum CameraCapture { photo, video }

/// Shows the attachment source chooser on mobile platforms.
///
/// On iOS this mirrors the action sheet Safari presents for file inputs:
/// photo library, camera, or the Files browser. On other mobile platforms a
/// Material bottom sheet is shown instead.
Future<AttachSource?> showAttachSourceSheet(BuildContext context) {
  final l = l10n(context);
  if (Theme.of(context).platform == TargetPlatform.iOS) {
    return showCupertinoModalPopup<AttachSource>(
      context: context,
      builder: (sheetContext) => CupertinoActionSheet(
        actions: [
          CupertinoActionSheetAction(
            onPressed: () => Navigator.pop(
              sheetContext,
              AttachSource.photoLibrary,
            ),
            child: _ActionLabel(
              label: l.attachSourcePhotoLibrary,
              icon: CupertinoIcons.photo_on_rectangle,
            ),
          ),
          CupertinoActionSheetAction(
            onPressed: () =>
                Navigator.pop(sheetContext, AttachSource.camera),
            child: _ActionLabel(
              label: l.attachSourceTakePhotoOrVideo,
              icon: CupertinoIcons.camera,
            ),
          ),
          CupertinoActionSheetAction(
            onPressed: () =>
                Navigator.pop(sheetContext, AttachSource.browse),
            child: _ActionLabel(
              label: l.attachSourceBrowse,
              icon: CupertinoIcons.ellipsis,
            ),
          ),
        ],
        cancelButton: CupertinoActionSheetAction(
          isDefaultAction: true,
          onPressed: () => Navigator.pop(sheetContext),
          child: Text(l.cancel),
        ),
      ),
    );
  }
  return showModalBottomSheet<AttachSource>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.photo_library_outlined),
            title: Text(l.attachSourcePhotoLibrary),
            onTap: () => Navigator.pop(
              sheetContext,
              AttachSource.photoLibrary,
            ),
          ),
          ListTile(
            leading: const Icon(Icons.photo_camera_outlined),
            title: Text(l.attachSourceTakePhotoOrVideo),
            onTap: () =>
                Navigator.pop(sheetContext, AttachSource.camera),
          ),
          ListTile(
            leading: const Icon(Icons.folder_open),
            title: Text(l.attachSourceBrowse),
            onTap: () =>
                Navigator.pop(sheetContext, AttachSource.browse),
          ),
        ],
      ),
    ),
  );
}

/// Asks whether to capture a photo or a video from the camera.
Future<CameraCapture?> showCameraCaptureSheet(BuildContext context) {
  final l = l10n(context);
  if (Theme.of(context).platform == TargetPlatform.iOS) {
    return showCupertinoModalPopup<CameraCapture>(
      context: context,
      builder: (sheetContext) => CupertinoActionSheet(
        actions: [
          CupertinoActionSheetAction(
            onPressed: () =>
                Navigator.pop(sheetContext, CameraCapture.photo),
            child: _ActionLabel(
              label: l.attachSourceTakePhoto,
              icon: CupertinoIcons.camera,
            ),
          ),
          CupertinoActionSheetAction(
            onPressed: () =>
                Navigator.pop(sheetContext, CameraCapture.video),
            child: _ActionLabel(
              label: l.attachSourceRecordVideo,
              icon: CupertinoIcons.video_camera,
            ),
          ),
        ],
        cancelButton: CupertinoActionSheetAction(
          isDefaultAction: true,
          onPressed: () => Navigator.pop(sheetContext),
          child: Text(l.cancel),
        ),
      ),
    );
  }
  return showModalBottomSheet<CameraCapture>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.photo_camera_outlined),
            title: Text(l.attachSourceTakePhoto),
            onTap: () =>
                Navigator.pop(sheetContext, CameraCapture.photo),
          ),
          ListTile(
            leading: const Icon(Icons.videocam_outlined),
            title: Text(l.attachSourceRecordVideo),
            onTap: () =>
                Navigator.pop(sheetContext, CameraCapture.video),
          ),
        ],
      ),
    ),
  );
}

class _ActionLabel extends StatelessWidget {
  final String label;
  final IconData icon;

  const _ActionLabel({required this.label, required this.icon});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(label),
        const SizedBox(width: 8),
        Icon(icon, size: 20),
      ],
    );
  }
}
