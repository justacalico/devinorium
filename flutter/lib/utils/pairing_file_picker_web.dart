import 'dart:typed_data';

/// No-op on web: the pairing setup view is only shown on native clients.
Future<Uint8List?> pickPairingFileContent() async => null;

/// No-op on web.
Future<Uint8List?> readPairingFileFromPath(String path) async => null;
