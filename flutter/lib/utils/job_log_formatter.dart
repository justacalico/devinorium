/// Prepares raw CI/CD trace output for display in Flutter.
///
/// Strips CSI (including private sequences like `ESC[?25l`) and OSC title
/// escape codes, and normalises line endings so logs render cleanly as plain
/// text.
class JobLogFormatter {
  // CSI: ESC[ <param> <intermediate> <final>
  static final _csi = RegExp('\u{001B}\\[[0-9;?]*[ -/]*[@-~]');
  // OSC: ESC] <payload> BEL  or  ESC] <payload> ESC\\
  static final _osc = RegExp('\u{001B}\\][^\u0007\u{001B}]*(?:\u0007|\u{001B}\\\\)');

  /// Strip ANSI escape sequences and convert `\r`/`\r\n` to `\n`.
  ///
  /// If [maxLength] is provided and the normalized output is longer, only the
  /// last [maxLength] characters are returned, prefixed with a truncation note.
  static String normalize(String trace, {int? maxLength}) {
    var normalized = trace.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    normalized = normalized.replaceAll(_csi, '');
    normalized = normalized.replaceAll(_osc, '');
    if (maxLength != null && normalized.length > maxLength) {
      final tail = normalized.substring(normalized.length - maxLength);
      return '... (log truncated, showing last $maxLength characters)\n\n$tail';
    }
    return normalized;
  }
}
