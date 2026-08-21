import 'dart:convert';

import 'package:devinorium_frontend/l10n/l10n.dart';
import 'package:devinorium_frontend/models/models.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

/// Renders file edits as inline diff cards (like t3code) — not collapsed
/// into a tool call. Shows the file path header with a status indicator
/// and the unified diff below it, directly in the chat stream.
class EditFileTool extends StatefulWidget {
  final ToolCallData tool;
  final VoidCallback? onOpenInFiles;

  const EditFileTool({
    super.key,
    required this.tool,
    this.onOpenInFiles,
  });

  @override
  State<EditFileTool> createState() => _EditFileToolState();
}

class _EditFileToolState extends State<EditFileTool> {
  int _selectedDiffIndex = 0;
  bool _collapsed = false;

  @override
  void didUpdateWidget(covariant EditFileTool oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.tool.diffs.length < oldWidget.tool.diffs.length) {
      _selectedDiffIndex = 0;
    } else if (_selectedDiffIndex >= widget.tool.diffs.length &&
        widget.tool.diffs.isNotEmpty) {
      _selectedDiffIndex = widget.tool.diffs.length - 1;
    }
  }

  @override
  Widget build(BuildContext context) {
    final diffs = widget.tool.diffs;
    if (diffs.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (diffs.length > 1) _buildDiffTabs(context, diffs),
        _buildDiffCard(context, _selectedDiff(diffs)),
      ],
    );
  }

  FileDiff _selectedDiff(List<FileDiff> diffs) {
    final idx = _selectedDiffIndex.clamp(0, diffs.length - 1);
    return diffs[idx];
  }

  Widget _buildDiffTabs(BuildContext context, List<FileDiff> diffs) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: SizedBox(
        height: 26,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: diffs.length,
          separatorBuilder: (_, __) => const SizedBox(width: 4),
          itemBuilder: (context, i) {
            final selected = i == _selectedDiffIndex;
            return InkWell(
              onTap: () => setState(() => _selectedDiffIndex = i),
              borderRadius: BorderRadius.circular(4),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: selected
                      ? theme.colorScheme.primaryContainer
                      : theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  _basename(diffs[i].path),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: selected
                        ? theme.colorScheme.onPrimaryContainer
                        : theme.colorScheme.onSurfaceVariant,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildDiffCard(BuildContext context, FileDiff diff) {
    final theme = Theme.of(context);
    final l = l10n(context);
    final isNewFile = diff.oldText == null;
    final statusColor = isNewFile
        ? theme.colorScheme.tertiary
        : theme.colorScheme.primary;

    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      decoration: BoxDecoration(
        border: Border.all(
          color: theme.colorScheme.outline.withValues(alpha: 0.3),
        ),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildFileHeader(context, l, diff, isNewFile, statusColor),
          if (!_collapsed) _buildDiffBody(context, diff, isNewFile),
        ],
      ),
    );
  }

  Widget _buildFileHeader(
    BuildContext context,
    AppLocalizations l,
    FileDiff diff,
    bool isNewFile,
    Color statusColor,
  ) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(5),
          topRight: Radius.circular(5),
        ),
      ),
      child: Row(
        children: [
          // Status indicator bar
          Container(
            width: 3,
            height: 16,
            decoration: BoxDecoration(
              color: statusColor,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 8),
          Icon(
            isNewFile ? Icons.add_circle_outline : Icons.edit_outlined,
            size: 14,
            color: statusColor,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              diff.path,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurface,
                fontFamily: 'monospace',
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          _CopyButton(
            text: diff.newText,
          ),
          if (widget.onOpenInFiles != null) ...[
            const SizedBox(width: 4),
            IconButton(
              tooltip: l.editFileOpenInFiles,
              iconSize: 14,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
              icon: Icon(Icons.open_in_new,
                  size: 14, color: theme.colorScheme.onSurfaceVariant),
              onPressed: widget.onOpenInFiles,
            ),
          ],
          const SizedBox(width: 4),
          InkWell(
            onTap: () => setState(() => _collapsed = !_collapsed),
            borderRadius: BorderRadius.circular(3),
            child: Icon(
              _collapsed ? Icons.expand_more : Icons.expand_less,
              size: 16,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDiffBody(
    BuildContext context,
    FileDiff diff,
    bool isNewFile,
  ) {
    final theme = Theme.of(context);
    final splitter = const LineSplitter();
    final oldLines = diff.oldText == null
        ? const <String>[]
        : splitter.convert(diff.oldText!);
    final newLines = splitter.convert(diff.newText);

    final hunks = isNewFile
        ? [_DiffHunk(lines: [
            for (final line in newLines) _DiffLine(_LineKind.added, line),
          ])]
        : _computeUnifiedDiff(oldLines, newLines);

    if (hunks.isEmpty || hunks.every((h) => h.lines.isEmpty)) {
      return Padding(
        padding: const EdgeInsets.all(12),
        child: Text(
          l10n(context).editFileNoDiff,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            fontFamily: 'monospace',
          ),
        ),
      );
    }

    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 400),
      child: SingleChildScrollView(
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 4),
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            borderRadius: const BorderRadius.only(
              bottomLeft: Radius.circular(5),
              bottomRight: Radius.circular(5),
            ),
          ),
          child: _UnifiedDiffView(hunks: hunks),
        ),
      ),
    );
  }

  String _basename(String path) {
    if (path.isEmpty) return path;
    if (path.contains('\\')) {
      return p.Context(style: p.Style.windows).basename(path);
    }
    return p.basename(path);
  }
}

enum _LineKind { context, added, removed }

class _UnifiedDiffView extends StatelessWidget {
  final List<_DiffHunk> hunks;
  const _UnifiedDiffView({required this.hunks});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rows = <Widget>[];
    for (final hunk in hunks) {
      for (final line in hunk.lines) {
        final (marker, color, bg) = switch (line.kind) {
          _LineKind.added => (
              '+',
              theme.colorScheme.primary,
              theme.colorScheme.primaryContainer.withValues(alpha: 0.20),
            ),
          _LineKind.removed => (
              '-',
              theme.colorScheme.error,
              theme.colorScheme.errorContainer.withValues(alpha: 0.20),
            ),
          _LineKind.context => (
              ' ',
              theme.colorScheme.onSurfaceVariant,
              Colors.transparent,
            ),
        };
        rows.add(Container(
          color: bg,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: SelectableText(
            '$marker ${line.text}',
            style: theme.textTheme.bodySmall?.copyWith(
              color: color,
              fontFamily: 'monospace',
              height: 1.4,
            ),
          ),
        ));
      }
    }
    if (rows.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: rows,
    );
  }
}

class _DiffHunk {
  final List<_DiffLine> lines;
  const _DiffHunk({required this.lines});
}

class _DiffLine {
  final _LineKind kind;
  final String text;
  const _DiffLine(this.kind, this.text);
}

/// Compute a simple unified diff using the classic LCS dynamic-programming
/// approach. Inputs are kept small (file previews), so the O(n*m) cost is
/// acceptable and avoids pulling in an extra dependency.
List<_DiffHunk> _computeUnifiedDiff(List<String> a, List<String> b) {
  final n = a.length;
  final m = b.length;
  if (n == 0 && m == 0) return const [];

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

  final lines = <_DiffLine>[];
  var i = 0;
  var j = 0;
  while (i < n && j < m) {
    if (a[i] == b[j]) {
      lines.add(_DiffLine(_LineKind.context, a[i]));
      i++;
      j++;
    } else if (dp[i + 1][j] >= dp[i][j + 1]) {
      lines.add(_DiffLine(_LineKind.removed, a[i]));
      i++;
    } else {
      lines.add(_DiffLine(_LineKind.added, b[j]));
      j++;
    }
  }
  while (i < n) {
    lines.add(_DiffLine(_LineKind.removed, a[i]));
    i++;
  }
  while (j < m) {
    lines.add(_DiffLine(_LineKind.added, b[j]));
    j++;
  }

  return [_DiffHunk(lines: lines)];
}

class _CopyButton extends StatelessWidget {
  final String text;
  const _CopyButton({required this.text});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: () async {
        await Clipboard.setData(ClipboardData(text: text));
      },
      borderRadius: BorderRadius.circular(4),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: Icon(Icons.copy_outlined,
            size: 14, color: theme.colorScheme.onSurfaceVariant),
      ),
    );
  }
}
