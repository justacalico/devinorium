/// A lightweight semantic version parser used to compare app and release
/// versions without adding a new dependency.
class Version implements Comparable<Version> {
  final List<int> core;
  final List<String>? pre;

  Version({required this.core, this.pre}) : assert(core.length == 3);

  static final _corePartPattern = RegExp(r'^(0|[1-9]\d*)$');
  static final _prePattern = RegExp(r'^[0-9A-Za-z-]+$');

  static Version? parse(String? input) {
    if (input == null || input.isEmpty) return null;
    var cleaned = input.trim();
    while (cleaned.startsWith('v') || cleaned.startsWith('V')) {
      cleaned = cleaned.substring(1);
    }

    final plus = cleaned.indexOf('+');
    if (plus != -1) cleaned = cleaned.substring(0, plus);

    final dash = cleaned.indexOf('-');
    var corePart = cleaned;
    List<String>? pre;
    if (dash != -1) {
      corePart = cleaned.substring(0, dash);
      pre = cleaned.substring(dash + 1).split('.');
      if (pre.isEmpty) return null;
    }

    final parts = corePart.split('.');
    if (parts.length != 3) return null;
    final core = <int>[];
    for (final p in parts) {
      if (!_corePartPattern.hasMatch(p)) return null;
      final n = int.tryParse(p);
      if (n == null || n < 0) return null;
      core.add(n);
    }

    if (pre != null) {
      for (final p in pre) {
        if (p.isEmpty || !_prePattern.hasMatch(p)) return null;
        if (_isNumeric(p) && p.length > 1 && p.startsWith('0')) return null;
      }
    }

    return Version(
      core: List.unmodifiable(core),
      pre: pre == null ? null : List.unmodifiable(pre),
    );
  }

  @override
  int compareTo(Version other) {
    for (var i = 0; i < 3; i++) {
      final cmp = core[i].compareTo(other.core[i]);
      if (cmp != 0) return cmp;
    }

    final aPre = pre;
    final bPre = other.pre;
    if (aPre == null && bPre == null) return 0;
    if (aPre == null) return 1;
    if (bPre == null) return -1;

    final len = aPre.length < bPre.length ? aPre.length : bPre.length;
    for (var i = 0; i < len; i++) {
      final cmp = _comparePre(aPre[i], bPre[i]);
      if (cmp != 0) return cmp;
    }

    return aPre.length.compareTo(bPre.length);
  }

  /// Pre-release identifiers are compared numerically when both are numeric,
  /// otherwise lexicographically. Purely numeric identifiers always have lower
  /// precedence than non-numeric identifiers.
  static int _comparePre(String a, String b) {
    if (a.isEmpty || b.isEmpty) return a.length.compareTo(b.length);

    final aNum = _tryParseBigInt(a);
    final bNum = _tryParseBigInt(b);
    if (aNum != null && bNum != null) {
      return aNum < bNum ? -1 : aNum > bNum ? 1 : 0;
    }
    if (aNum != null) return -1;
    if (bNum != null) return 1;
    return a.compareTo(b).sign;
  }

  static bool _isNumeric(String value) =>
      value.isNotEmpty && value.runes.every((r) => r >= 48 && r <= 57);

  static BigInt? _tryParseBigInt(String value) {
    if (!_isNumeric(value)) return null;
    try {
      return BigInt.parse(value);
    } on FormatException {
      return null;
    }
  }

  @override
  String toString() {
    final buffer = StringBuffer()..write(core.join('.'));
    if (pre != null && pre!.isNotEmpty) {
      buffer
        ..write('-')
        ..write(pre!.join('.'));
    }
    return buffer.toString();
  }

  @override
  bool operator ==(Object other) =>
      other is Version &&
      _listEquals(core, other.core) &&
      _listEquals(pre, other.pre);

  @override
  int get hashCode => Object.hash(
        Object.hashAll(core),
        pre == null ? 0 : Object.hashAll(pre!),
      );

  static bool _listEquals<T>(List<T>? a, List<T>? b) {
    if (a == null) return b == null;
    if (b == null || a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
