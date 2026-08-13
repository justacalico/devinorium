import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

Future<void> downloadImpl(String content, String filename) async {
  await FilePicker.saveFile(
    fileName: filename,
    bytes: Uint8List.fromList(utf8.encode(content)),
    type: FileType.custom,
    allowedExtensions: const ['json'],
  );
}
