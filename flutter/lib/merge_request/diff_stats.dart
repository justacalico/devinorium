import 'dart:convert';

/// Added and removed line counts parsed from a unified diff.
class DiffStats {
  final int additions;
  final int deletions;

  const DiffStats({this.additions = 0, this.deletions = 0});

  /// Whether the diff had no countable lines (binary or collapsed diffs).
  bool get isZero => additions == 0 && deletions == 0;

  /// Counts the `+`/`-` content lines in a unified [diff].
  ///
  /// Counting only starts after the first `@@` hunk header, so file headers
  /// (`---`, `+++`, `diff`, `index`, ...) are never mistaken for content.
  /// Binary or collapsed diffs have no hunks and report zero.
  factory DiffStats.parse(String diff) {
    var additions = 0;
    var deletions = 0;
    var inHunks = false;
    for (final line in const LineSplitter().convert(diff)) {
      if (line.startsWith('@@')) {
        inHunks = true;
        continue;
      }
      if (!inHunks) continue;
      if (line.startsWith('+')) {
        additions++;
      } else if (line.startsWith('-')) {
        deletions++;
      }
    }
    return DiffStats(additions: additions, deletions: deletions);
  }

  /// Sums [stats] into a single total.
  static DiffStats total(Iterable<DiffStats> stats) {
    var additions = 0;
    var deletions = 0;
    for (final s in stats) {
      additions += s.additions;
      deletions += s.deletions;
    }
    return DiffStats(additions: additions, deletions: deletions);
  }
}
