import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

/// Pick a pairing file. On Linux, fall back to a system dialog if the
/// XDG Desktop Portal is not available. Returns `null` if the user cancels
/// or no dialog can be opened.
Future<Uint8List?> pickPairingFileContent() async {
  try {
    return await _pickWithFilePicker();
  } on Object {
    if (Platform.isLinux) {
      try {
        return await _pickWithLinuxDialog();
      } on Object {
        return null;
      }
    }
    return null;
  }
}

/// Read a pairing file from an absolute path.
Future<Uint8List?> readPairingFileFromPath(String path) async {
  try {
    return await File(path).readAsBytes();
  } on Object {
    return null;
  }
}

Future<Uint8List?> _pickWithFilePicker() async {
  final result = await FilePicker.pickFiles(
    type: FileType.any,
    allowMultiple: false,
    withData: true,
  );

  if (result == null || result.files.isEmpty) return null;

  final bytes = result.files.first.bytes;
  if (bytes == null || bytes.isEmpty) return null;

  return bytes;
}

Future<Uint8List?> _pickWithLinuxDialog() async {
  final path = await _pickPathWithLinuxDialog();
  if (path == null || path.isEmpty) return null;
  return readPairingFileFromPath(path);
}

Future<String?> _pickPathWithLinuxDialog() async {
  final commands = <String, List<String>>{
    'zenity': [
      '--file-selection',
      '--file-filter=JSON files | *.json',
      '--title=选择配对文件',
    ],
    'kdialog': [
      '--getopenfilename',
      '.',
      '*.json',
    ],
  };

  for (final entry in commands.entries) {
    try {
      final result = await Process.run(
        entry.key,
        entry.value,
        runInShell: false,
      );

      if (result.exitCode != 0) return null;

      final output = (result.stdout as String?)?.trim() ?? '';
      if (output.isEmpty) return null;

      return output;
    } on Object {
      // Executable not found or failed; try the next one.
    }
  }

  return null;
}
