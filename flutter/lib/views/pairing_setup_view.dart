import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../state/app_state.dart';
import '../utils/pairing_file_picker.dart' as picker;

/// Initial screen for native clients: import a pairing file downloaded from
/// the web UI. The file contains the server URL, bearer token, and username.
class PairingSetupView extends StatefulWidget {
  final Future<Uint8List?> Function()? pickFile;

  const PairingSetupView({super.key, this.pickFile});

  @override
  State<PairingSetupView> createState() => _PairingSetupViewState();
}

class _PairingSetupViewState extends State<PairingSetupView> {
  bool _picking = false;

  Future<void> _pickFile() async {
    setState(() => _picking = true);
    try {
      final pick = widget.pickFile ?? picker.pickPairingFileContent;
      final bytes = await pick();
      if (bytes == null || bytes.isEmpty) {
        setState(() => _picking = false);
        await _manualPathFallback();
      } else {
        await _handleBytes(bytes);
      }
    } on FormatException {
      _showSnack('Could not parse file');
    } on Exception {
      _showSnack('Could not open file picker');
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  Future<void> _manualPathFallback() async {
    final controller = TextEditingController();
    final path = await showDialog<String?>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Enter pairing file path'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            hintText: '/path/to/devinorium-pairing.json',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: const Text('OK'),
          ),
        ],
      ),
    );
    controller.dispose();

    if (path == null || path.isEmpty) {
      _showSnack('No file selected');
      return;
    }

    final bytes = await picker.readPairingFileFromPath(path);
    await _handleBytes(bytes);
  }

  Future<void> _handleBytes(Uint8List? bytes) async {
    if (bytes == null || bytes.isEmpty) {
      _showSnack('Could not read file content');
      return;
    }
    if (bytes.length > 1024 * 1024) {
      _showSnack('Pairing file is too large');
      return;
    }

    final json = jsonDecode(utf8.decode(bytes));
    if (json is! Map<String, dynamic>) {
      _showSnack('Invalid file format');
      return;
    }

    final pairing = PairingResponse.fromJson(json);
    if (pairing.token.isEmpty || pairing.serverUrl.isEmpty) {
      _showSnack('Pairing file is missing required fields');
      return;
    }

    if (!mounted) return;
    await context.read<AppState>().completePairing(pairing);
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final error = state.setupError;

    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  'Devinorium',
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                const SizedBox(height: 16),
                Text(
                  'Import a pairing file to connect to the server.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
                const SizedBox(height: 32),
                if (error.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: Text(
                      error,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                FilledButton.icon(
                  onPressed: _picking ? null : _pickFile,
                  icon: _picking
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.file_open),
                  label: const Text('Select pairing file'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
