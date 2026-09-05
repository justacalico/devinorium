import 'package:devinorium_frontend/merge_request/diff_stats.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DiffStats.parse', () {
    test('counts added and removed lines', () {
      const diff = '@@ -1,3 +1,4 @@\n context\n-removed\n+added\n+extra\n';
      final stats = DiffStats.parse(diff);
      expect(stats.additions, 2);
      expect(stats.deletions, 1);
    });

    test('ignores metadata before the first hunk header', () {
      const diff =
          'diff --git a/a.txt b/a.txt\n'
          'index 111..222 100644\n'
          '--- a/a.txt\n'
          '+++ b/a.txt\n'
          '@@ -1 +1 @@\n-old\n+new\n';
      final stats = DiffStats.parse(diff);
      expect(stats.additions, 1);
      expect(stats.deletions, 1);
    });

    test('counts content lines that look like file headers', () {
      const diff = '@@ -1,2 +1,2 @@\n----\n++++\n';
      final stats = DiffStats.parse(diff);
      expect(stats.additions, 1);
      expect(stats.deletions, 1);
    });

    test('counts content lines that start with @@', () {
      const diff = '@@ -1,2 +1,2 @@\n-@@ old\n+@@ new\n @@ ctx\n';
      final stats = DiffStats.parse(diff);
      expect(stats.additions, 1);
      expect(stats.deletions, 1);
    });

    test('ignores no-newline markers between hunks', () {
      const diff =
          '@@ -1 +1 @@\n-a\n\\ No newline at end of file\n+b\n'
          '@@ -5 +5 @@\n-c\n+d\n';
      final stats = DiffStats.parse(diff);
      expect(stats.additions, 2);
      expect(stats.deletions, 2);
    });

    test('counts across multiple hunks', () {
      const diff = '@@ -1 +1 @@\n-a\n+b\n@@ -10 +10,2 @@\n-c\n+d\n+e\n';
      final stats = DiffStats.parse(diff);
      expect(stats.additions, 3);
      expect(stats.deletions, 2);
    });

    test('handles CRLF line endings', () {
      const diff = '@@ -1 +1 @@\r\n-old\r\n+new\r\n';
      final stats = DiffStats.parse(diff);
      expect(stats.additions, 1);
      expect(stats.deletions, 1);
    });

    test('returns zero for empty and binary diffs', () {
      final empty = DiffStats.parse('');
      expect(empty.additions, 0);
      expect(empty.deletions, 0);

      final binary = DiffStats.parse('Binary files a/a.png and b/a.png differ');
      expect(binary.additions, 0);
      expect(binary.deletions, 0);
    });

    test('ignores the no-newline marker', () {
      const diff =
          '@@ -1 +1 @@\n-line\n\\ No newline at end of file\n'
          '+line\n\\ No newline at end of file\n';
      final stats = DiffStats.parse(diff);
      expect(stats.additions, 1);
      expect(stats.deletions, 1);
    });
  });

  group('DiffStats.total', () {
    test('sums multiple diffs', () {
      final total = DiffStats.total(const [
        DiffStats(additions: 3, deletions: 1),
        DiffStats(additions: 0, deletions: 2),
        DiffStats(),
      ]);
      expect(total.additions, 3);
      expect(total.deletions, 3);
    });

    test('empty input is zero', () {
      final total = DiffStats.total(const []);
      expect(total.additions, 0);
      expect(total.deletions, 0);
    });
  });
}
