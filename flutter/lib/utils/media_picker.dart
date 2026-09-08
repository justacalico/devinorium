import 'package:image_picker/image_picker.dart';

/// Picks media from the device gallery or camera.
///
/// On iOS the file picker only exposes the document browser, so photos and
/// videos are picked through this interface instead.
abstract class MediaPicker {
  Future<List<XFile>> pickGalleryMedia({required bool multiple});
  Future<XFile?> capturePhoto();
  Future<XFile?> captureVideo();
}

class ImagePickerMediaPicker implements MediaPicker {
  ImagePickerMediaPicker({ImagePicker? picker})
    : _picker = picker ?? ImagePicker();

  final ImagePicker _picker;

  @override
  Future<List<XFile>> pickGalleryMedia({required bool multiple}) async {
    if (!multiple) {
      final file = await _picker.pickMedia();
      return file == null ? const [] : [file];
    }
    return _picker.pickMultipleMedia();
  }

  @override
  Future<XFile?> capturePhoto() =>
      _picker.pickImage(source: ImageSource.camera);

  @override
  Future<XFile?> captureVideo() =>
      _picker.pickVideo(source: ImageSource.camera);
}
