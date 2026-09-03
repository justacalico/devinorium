import 'package:devinorium_frontend/l10n/l10n.dart';
import 'dart:convert';

import 'package:devinorium_frontend/models/models.dart';
import 'package:flutter/material.dart';

/// Maximum number of diff lines to render. Files larger than this show
/// a truncated view with a note.
const _maxRenderLines = 500;

/// Renders a single file diff inline, with added/removed/context lines and
/// a small context window. It can be embedded in tool call cards or full-page
/// file viewers; when [maxHeight] is set it is wrapped in a scrollable
/// constrained box, otherwise it is a plain scrollable widget that the caller
/// should bound.
class DiffView extends StatefulWidget {
  final FileDiff diff;
  final double? maxHeight;

  const DiffView({
    super.key,
    required this.diff,
    this.maxHeight,
  });

  @override
  State<DiffView> createState() => _DiffViewState();
}

class _DiffViewState extends State<DiffView> {
  /// Cache key -> computed diff lines. Avoids recomputing the O(n*m) LCS
  /// on every rebuild when the diff content hasn't changed.
  _CachedDiff? _cachedDiff;

  @override
  void didUpdateWidget(covariant DiffView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.diff != oldWidget.diff) {
      _cachedDiff = null;
    }
  }

  _CachedDiff _getDiffLines(FileDiff diff) {
    final key = '${diff.oldText ?? ''}\x00${diff.newText}';
    if (_cachedDiff != null && _cachedDiff!.key == key) {
      return _cachedDiff!;
    }

    final splitter = const LineSplitter();
    final oldLines = diff.oldText == null
        ? const <String>[]
        : splitter.convert(diff.oldText!);
    final newLines = splitter.convert(diff.newText);

    final List<_DiffLine> lines;
    if (diff.oldText == null) {
      lines = [
        for (final line in newLines) _DiffLine(_LineKind.added, line),
      ];
    } else {
      lines = _computeUnifiedDiff(oldLines, newLines);
    }

    final truncated = lines.length > _maxRenderLines;
    final visibleLines =
        truncated ? lines.sublist(0, _maxRenderLines) : lines;

    _cachedDiff = _CachedDiff(
      key: key,
      lines: visibleLines,
      totalLines: lines.length,
      truncated: truncated,
    );
    return _cachedDiff!;
  }

  @override
  Widget build(BuildContext context) {
    final l = l10n(context);
    final cached = _getDiffLines(widget.diff);

    Widget body;
    if (cached.lines.isEmpty) {
      body = Padding(
        padding: const EdgeInsets.all(12),
        child: Text(
          l.editFileNoDiff,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontFamily: 'monospace',
              ),
        ),
      );
    } else {
      body = _DiffTextView(cached: cached);
    }

    final scrollable = SingleChildScrollView(child: body);
    if (widget.maxHeight != null) {
      return ConstrainedBox(
        constraints: BoxConstraints(maxHeight: widget.maxHeight!),
        child: scrollable,
      );
    }
    return scrollable;
  }
}

/// Holds a cached diff computation so it's not recomputed on every rebuild.
class _CachedDiff {
  final String key;
  final List<_DiffLine> lines;
  final int totalLines;
  final bool truncated;

  const _CachedDiff({
    required this.key,
    required this.lines,
    required this.totalLines,
    required this.truncated,
  });
}

enum _LineKind { context, added, removed, skip }

class _DiffLine {
  final _LineKind kind;
  final String text;
  const _DiffLine(this.kind, this.text);
}

/// Renders the entire diff as a single [SelectableText.rich] widget with
/// per-line [TextSpan]s. This is dramatically cheaper than creating one
/// [SelectableText] per line (one render object vs hundreds).
class _DiffTextView extends StatelessWidget {
  final _CachedDiff cached;
  const _DiffTextView({required this.cached});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final addedColor = theme.colorScheme.primary;
    final removedColor = theme.colorScheme.error;
    final contextColor = theme.colorScheme.onSurfaceVariant;
    final addedBg = theme.colorScheme.primaryContainer.withValues(alpha: 0.20);
    final removedBg =
        theme.colorScheme.errorContainer.withValues(alpha: 0.20);

    final baseStyle = theme.textTheme.bodySmall?.copyWith(
      fontFamily: 'monospace',
      height: 1.4,
    );

    final spans = <TextSpan>[];
    for (final line in cached.lines) {
      if (line.kind == _LineKind.skip) {
        spans.add(TextSpan(
          text: '${line.text}\n',
          style: baseStyle?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            fontStyle: FontStyle.italic,
          ),
        ));
        continue;
      }
      final (marker, color, bg) = switch (line.kind) {
        _LineKind.added => ('+', addedColor, addedBg),
        _LineKind.removed => ('-', removedColor, removedBg),
        _LineKind.context => (' ', contextColor, Colors.transparent),
        _LineKind.skip => ('', contextColor, Colors.transparent),
      };
      spans.add(TextSpan(
        text: '$marker ${line.text}\n',
        style: baseStyle?.copyWith(color: color, backgroundColor: bg),
      ));
    }

    if (cached.truncated) {
      final hidden = cached.totalLines - cached.lines.length;
      spans.add(TextSpan(
        text: '\n${l10n(context).diffViewMoreLines(hidden)}',
        style: baseStyle?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          fontStyle: FontStyle.italic,
        ),
      ));
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: SelectableText.rich(
        TextSpan(children: spans),
        style: baseStyle,
      ),
    );
  }
}

/// Number of context lines to keep around each changed region.
const _contextLines = 3;

/// Compute a simple unified diff using the classic LCS dynamic-programming
/// approach, then trim to only the changed hunks with a small context
/// window (like `git diff`). Result is cached by the caller so this only
/// runs once per unique (oldText, newText) pair.
List<_DiffLine> _computeUnifiedDiff(List<String> a, List<String> b) {
  final n = a.length;
  final m = b.length;
  if (n == 0 && m == 0) return const [];
  if (n == 0) {
    return [for (final line in b) _DiffLine(_LineKind.added, line)];
  }
  if (m == 0) {
    return [for (final line in a) _DiffLine(_LineKind.removed, line)];
  }

  final dp = List<List<int>>.generate(
    n + 1,
    (_) => List<int>.filled(m + 1, 0),
  );
  for (var i = n - 1; i >= 0; i--) {
    for (var j = m - 1; j >= 0; j--) {
      dp[i][j] = a[i] == b[j]
          ? dp[i + 1][j + 1] + 1
          : dp[i + 1][j] > dp[i][j + 1]
              ? dp[i + 1][j]
              : dp[i][j + 1];
    }
  }

  final raw = <_DiffLine>[];
  var i = 0;
  var j = 0;
  while (i < n && j < m) {
    if (a[i] == b[j]) {
      raw.add(_DiffLine(_LineKind.context, a[i]));
      i++;
      j++;
    } else if (dp[i + 1][j] >= dp[i][j + 1]) {
      raw.add(_DiffLine(_LineKind.removed, a[i]));
      i++;
    } else {
      raw.add(_DiffLine(_LineKind.added, b[j]));
      j++;
    }
  }
  while (i < n) {
    raw.add(_DiffLine(_LineKind.removed, a[i]));
    i++;
  }
  while (j < m) {
    raw.add(_DiffLine(_LineKind.added, b[j]));
    j++;
  }

  return _extractHunks(raw);
}

/// Keep only changed lines plus [_contextLines] of surrounding context.
/// Consecutive changed regions separated by fewer than 2*_contextLines
/// context lines are merged into a single hunk.
List<_DiffLine> _extractHunks(List<_DiffLine> raw) {
  if (raw.isEmpty) return const [];

  final changed = <int>[];
  for (var idx = 0; idx < raw.length; idx++) {
    if (raw[idx].kind != _LineKind.context) {
      changed.add(idx);
    }
  }
  if (changed.isEmpty) return const [];

  final keep = List<bool>.filled(raw.length, false);
  for (final c in changed) {
    final start = (c - _contextLines).clamp(0, raw.length - 1);
    final end = (c + _contextLines).clamp(0, raw.length - 1);
    for (var k = start; k <= end; k++) {
      keep[k] = true;
    }
  }

  final result = <_DiffLine>[];
  var prevKept = false;
  for (var idx = 0; idx < raw.length; idx++) {
    if (keep[idx]) {
      if (!prevKept && result.isNotEmpty) {
        result.add(const _DiffLine(_LineKind.skip, '…'));
      }
      result.add(raw[idx]);
      prevKept = true;
    } else {
      prevKept = false;
    }
  }

  return result;
}
