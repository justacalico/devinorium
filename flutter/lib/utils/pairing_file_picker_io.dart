import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

/// Picks a pairing file. On Linux, falls back to a system dialog if the
/// XDG Desktop Portal is not available. Returns `null` if the user cancels
/// or no dialog can be opened.
Future<Uint8List?> pickPairingFileContent() async {
  try {
    return await _pickWithFilePicker();
  } on Exception {
    if (Platform.isLinux) {
      return await _pickWithLinuxDialog();
    }
    rethrow;
  }
}

/// Reads a pairing file from an absolute path.
Future<Uint8List?> readPairingFileFromPath(String path) async {
  try {
    final file = File(path);
    if (!await file.exists()) return null;

    final stat = await file.stat();
    if (stat.type != FileSystemEntityType.file) return null;

    return await file.readAsBytes();
  } on Exception {
    return null;
  }
}

Future<Uint8List?> _pickWithFilePicker() async {
  final file = await FilePicker.pickFile(
    type: FileType.any,
  );

  if (file == null) return null;

  final bytes = await file.readAsBytes();
  if (bytes.isEmpty) return null;

  return bytes;
}

Future<Uint8List?> _pickWithLinuxDialog() async {
  final path = await _pickPathWithLinuxDialog();
  if (path == null || path.isEmpty) return null;
  return readPairingFileFromPath(path);
}

Future<String?> _pickPathWithLinuxDialog() async {
  final home = Platform.environment['HOME'] ?? '.';
  final commands = <String, List<String>>{
    'zenity': [
      '--file-selection',
      '--file-filter=JSON files | *.json',
      '--title=Select pairing file',
    ],
    'kdialog': [
      '--getopenfilename',
      home,
      '*.json',
    ],
  };

  for (final entry in commands.entries) {
    try {
      final result = await Process.run(
        entry.key,
        entry.value,
        runInShell: false,
        stdoutEncoding: utf8,
      );

      if (result.exitCode != 0) return null;

      final output = (result.stdout as String?)?.trim() ?? '';
      if (output.isEmpty) return null;

      return output;
    } on Exception {
      // Executable not found or failed to start; try the next one.
    }
  }

  return null;
}
