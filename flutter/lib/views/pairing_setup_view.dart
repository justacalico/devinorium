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
      _showSnack('无法解析文件');
    } on Exception {
      _showSnack('无法打开文件选择器');
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  Future<void> _manualPathFallback() async {
    final controller = TextEditingController();
    final path = await showDialog<String?>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('输入配对文件路径'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            hintText: '/path/to/devinorium-pairing.json',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    controller.dispose();

    if (path == null || path.isEmpty) {
      _showSnack('未选择文件');
      return;
    }

    final bytes = await picker.readPairingFileFromPath(path);
    await _handleBytes(bytes);
  }

  Future<void> _handleBytes(Uint8List? bytes) async {
    if (bytes == null || bytes.isEmpty) {
      _showSnack('无法读取文件内容');
      return;
    }
    if (bytes.length > 1024 * 1024) {
      _showSnack('配对文件过大');
      return;
    }

    final json = jsonDecode(utf8.decode(bytes));
    if (json is! Map<String, dynamic>) {
      _showSnack('文件格式不正确');
      return;
    }

    final pairing = PairingResponse.fromJson(json);
    if (pairing.token.isEmpty || pairing.serverUrl.isEmpty) {
      _showSnack('配对文件缺少必要字段');
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
                  '导入配对文件以连接到服务器。',
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
                  label: const Text('选择配对文件'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
