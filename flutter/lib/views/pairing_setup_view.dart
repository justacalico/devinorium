import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/l10n.dart';
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
    final l = l10n(context);
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
      _showSnack(l.couldNotParseFile);
    } on Exception {
      _showSnack(l.couldNotOpenFilePicker);
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  Future<void> _manualPathFallback() async {
    final l = l10n(context);
    final controller = TextEditingController();
    final path = await showDialog<String?>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l.enterPairingFilePath),
        content: TextField(
          controller: controller,
          decoration: InputDecoration(
            hintText: l.pairingFilePathHint,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(l.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: Text(l.ok),
          ),
        ],
      ),
    );
    controller.dispose();

    if (path == null || path.isEmpty) {
      _showSnack(l.noFileSelected);
      return;
    }

    final bytes = await picker.readPairingFileFromPath(path);
    await _handleBytes(bytes);
  }

  Future<void> _handleBytes(Uint8List? bytes) async {
    final l = l10n(context);
    if (bytes == null || bytes.isEmpty) {
      _showSnack(l.couldNotReadFileContent);
      return;
    }
    if (bytes.length > 1024 * 1024) {
      _showSnack(l.pairingFileTooLarge);
      return;
    }

    final json = jsonDecode(utf8.decode(bytes));
    if (json is! Map<String, dynamic>) {
      _showSnack(l.invalidFileFormat);
      return;
    }

    final pairing = PairingResponse.fromJson(json);
    if (pairing.token.isEmpty || pairing.serverUrl.isEmpty) {
      _showSnack(l.pairingFileMissingFields);
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
                  l10n(context).appTitle,
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                const SizedBox(height: 16),
                Text(
                  l10n(context).pairingSetupSubtitle,
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
                  label: Text(l10n(context).selectPairingFile),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
