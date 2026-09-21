import 'dart:convert';
import 'dart:typed_data';

import '../models/models.dart';

/// Token estimation for the composer, mirroring `src/providers/tokens.rs`.
///
/// There is no real tokenizer on either side; both estimate so the numbers
/// stay comparable. ASCII text runs about four characters per token while
/// non-ASCII text (CJK, emoji) is closer to one per character. Reference
/// chips use the same flat rates the backend charges stored attachment
/// metadata. Estimates err high: they drive warnings and a pre-send limit
/// check, where an overestimate is safer than an overflow mid-turn.

/// Per-message wrapper cost (role markers, separators).
const messageOverheadTokens = 8;

/// A path reference renders as one line in a prompt block plus its header.
const pathRefTokens = 40;

/// A thread reference embeds a transcript capped at 4000 characters.
const threadRefTokens = 1100;

/// A machine reference expands to a fixed control-instruction block.
const machineRefTokens = 350;

/// Non-text attachments reach the provider as a marker line only.
const binaryAttachmentTokens = 40;

/// Headroom reserved for the reply when neither the thread nor the model
/// declares an output cap. Mirrors DEFAULT_OUTPUT_HEADROOM in context.rs.
const defaultOutputHeadroom = 8192;

/// Rough token count for a string: ASCII at four per token, everything else
/// one per character.
int estimateTokens(String text) {
  var ascii = 0;
  var other = 0;
  for (final rune in text.runes) {
    if (rune < 128) {
      ascii++;
    } else {
      other++;
    }
  }
  return (ascii + 3) ~/ 4 + other;
}

/// The mode instruction the backend prepends/appends to every provider
/// prompt. Kept in sync with `apply_interaction_mode_prefix`.
String composeModePrompt(String prompt, String mode) {
  switch (mode) {
    case 'plan':
      return 'You are in Plan mode. First produce a concise, '
          'decision-complete plan and do not run tools, edit files, or '
          'execute commands until the user confirms. Wrap the final plan in '
          'a `<proposed_plan>` block with `<step status="pending">...</step>` '
          'children. At most one step may be `in_progress`.\n\n$prompt';
    case 'ask':
      return "You are in Ask mode. Answer the user's question directly and "
          'do not use tools, edit files, or execute commands.\n\n$prompt';
    default:
      return '$prompt\n\nWhen working on a multi-step task, you may track '
          'progress by emitting `<update_plan explanation="..."><step '
          'status="pending|in_progress|completed">...</step></update_plan>` '
          'blocks. Only one step should be `in_progress` at a time.';
  }
}

/// Whether the attachment's bytes are likely to be read into context as
/// text. Mirrors `is_text_like` on the backend.
bool isTextLikeMime(String mime, String filename) {
  final m = mime.toLowerCase();
  if (m.startsWith('text/') || m == 'image/svg+xml') return true;
  const textMimes = {
    'application/json',
    'application/xml',
    'application/javascript',
    'application/x-javascript',
    'application/yaml',
    'application/x-yaml',
    'application/toml',
    'application/x-sh',
    'application/x-httpd-php',
    'application/typescript',
  };
  if (textMimes.contains(m) || m.endsWith('+json') || m.endsWith('+xml')) {
    return true;
  }
  const textExts = {
    'txt',
    'md',
    'markdown',
    'rs',
    'py',
    'js',
    'ts',
    'tsx',
    'jsx',
    'json',
    'jsonl',
    'yaml',
    'yml',
    'toml',
    'xml',
    'html',
    'htm',
    'css',
    'scss',
    'sh',
    'bash',
    'zsh',
    'fish',
    'c',
    'h',
    'cc',
    'cpp',
    'hpp',
    'java',
    'kt',
    'kts',
    'go',
    'rb',
    'php',
    'swift',
    'cs',
    'dart',
    'lua',
    'r',
    'sql',
    'csv',
    'tsv',
    'ini',
    'cfg',
    'conf',
    'env',
    'log',
    'svg',
  };
  final dot = filename.lastIndexOf('.');
  if (dot < 0) return false;
  return textExts.contains(filename.substring(dot + 1).toLowerCase());
}

/// (width, height) parsed out of a PNG, GIF, or JPEG header.
(int, int)? _imageDimensions(Uint8List data) {
  // PNG: 8-byte signature, IHDR length/type, width/height BE u32.
  if (data.length >= 24 &&
      data[0] == 0x89 &&
      data[1] == 0x50 &&
      data[2] == 0x4E &&
      data[3] == 0x47) {
    final w = ByteData.sublistView(data, 16, 20).getUint32(0);
    final h = ByteData.sublistView(data, 20, 24).getUint32(0);
    if (w > 0 && h > 0) return (w, h);
    return null;
  }
  // GIF: "GIF8x[89]a", width/height LE u16.
  if (data.length >= 10 &&
      data[0] == 0x47 &&
      data[1] == 0x49 &&
      data[2] == 0x46 &&
      data[3] == 0x38 &&
      (data[4] == 0x37 || data[4] == 0x39) &&
      data[5] == 0x61) {
    final w = ByteData.sublistView(data, 6, 8).getUint16(0, Endian.little);
    final h = ByteData.sublistView(data, 8, 10).getUint16(0, Endian.little);
    if (w > 0 && h > 0) return (w, h);
    return null;
  }
  // JPEG: walk markers until a start-of-frame segment holds the size.
  if (data.length >= 4 && data[0] == 0xFF && data[1] == 0xD8) {
    var i = 2;
    while (i + 9 < data.length) {
      if (data[i] != 0xFF) {
        i++;
        continue;
      }
      final marker = data[i + 1];
      if (marker >= 0xC0 &&
          marker <= 0xCF &&
          marker != 0xC4 &&
          marker != 0xC8 &&
          marker != 0xCC) {
        final view = ByteData.sublistView(data);
        final h = view.getUint16(i + 5);
        final w = view.getUint16(i + 7);
        if (w > 0 && h > 0) return (w, h);
        return null;
      }
      final len = ByteData.sublistView(data, i + 2, i + 4).getUint16(0);
      i += 2 + (len > 0 ? len : 1);
    }
  }
  return null;
}

/// Estimated vision tokens for a raster image: roughly 750 pixels per token,
/// clamped so icons and giant rasters stay sane.
int _imageTokens(Uint8List data) {
  final dims = _imageDimensions(data);
  final estimated = dims != null
      ? (dims.$1 * dims.$2) ~/ 750
      : data.length ~/ 750;
  return estimated.clamp(85, 16000);
}

/// Estimated tokens for one pending upload. Raster images are priced by
/// resolution, text-like files by content, and other binaries by the marker
/// line the provider emits.
int estimateAttachmentTokens(String filename, String mime, Uint8List bytes) {
  final wrapper = estimateTokens('[Attachment: $filename]') + 4;
  final m = mime.toLowerCase();
  if (m.startsWith('image/') && m != 'image/svg+xml') {
    return wrapper + _imageTokens(bytes);
  }
  if (isTextLikeMime(m, filename)) {
    try {
      return wrapper + estimateTokens(utf8.decode(bytes));
    } on FormatException {
      return wrapper + bytes.length ~/ 64;
    }
  }
  return wrapper + binaryAttachmentTokens;
}

/// Estimated tokens for the message a send would produce: the prompt with
/// its mode instruction, attachment contents, and a flat cost per reference
/// chip (the backend expands those server-side; the flat rates match the
/// stored-message estimate).
int estimateDraftTokens({
  required String prompt,
  String mode = 'code',
  List<({String filename, String mime, Uint8List bytes})> attachments =
      const [],
  List<PathRef> pathRefs = const [],
  List<ThreadReference> threadReferences = const [],
  List<MachineReference> machineReferences = const [],
}) {
  var total = estimateTokens(composeModePrompt(prompt, mode));
  for (final a in attachments) {
    total += estimateAttachmentTokens(a.filename, a.mime, a.bytes);
  }
  total += pathRefs.length * pathRefTokens;
  total += threadReferences.length * threadRefTokens;
  total += machineReferences.length * machineRefTokens;
  return total + messageOverheadTokens;
}
