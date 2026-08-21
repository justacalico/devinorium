import 'dart:convert';

import 'package:devinorium_frontend/l10n/l10n.dart';
import 'package:devinorium_frontend/models/models.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

/// A styled tool-call card for the `edit` kind that renders an inline diff
/// (or a side-by-side before/after) for each file changed by the call.
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
  bool _expanded = false;
  int _selectedDiffIndex = 0;
  _DiffView _view = _DiffView.inline;
  bool _copied = false;

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
    final theme = Theme.of(context);
    final l = l10n(context);
    final tool = widget.tool;
    final diffs = tool.diffs;

    final statusColor = switch (tool.status) {
      'completed' => theme.colorScheme.primary,
      'failed' => theme.colorScheme.error,
      _ => theme.colorScheme.onSurfaceVariant,
    };
    final statusIcon = switch (tool.status) {
      'completed' => Icons.check,
      'failed' => Icons.error_outline,
      _ => Icons.play_circle_outline,
    };

    final titleText = diffs.isEmpty
        ? tool.title
        : l.editFileTitle(_basename(diffs.first.path));

    return Semantics(
      button: true,
      expanded: _expanded,
      label: titleText,
      child: InkWell(
        onTap: () => setState(() => _expanded = !_expanded),
        borderRadius: BorderRadius.circular(6),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          decoration: BoxDecoration(
            color: _expanded
                ? theme.colorScheme.surfaceContainer
                : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          margin: const EdgeInsets.only(bottom: 2),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.edit_outlined,
                      size: 16, color: theme.colorScheme.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      titleText,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurface,
                        fontWeight: FontWeight.w500,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (diffs.length == 1)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: _Badge(
                        label: diffs.first.oldText == null
                            ? l.editFileNewFile
                            : l.editFileModified,
                        color: diffs.first.oldText == null
                            ? theme.colorScheme.tertiary
                            : theme.colorScheme.primary,
                      ),
                    ),
                  if (diffs.length > 1)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: Text(
                        '${diffs.length}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  Icon(statusIcon, size: 14, color: statusColor),
                  const SizedBox(width: 4),
                  Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    size: 14,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ],
              ),
              if (_expanded) _buildExpanded(context, l, diffs),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildExpanded(
    BuildContext context,
    AppLocalizations l,
    List<FileDiff> diffs,
  ) {
    final theme = Theme.of(context);

    if (diffs.isEmpty) {
      return Padding(
        padding: const EdgeInsets.only(top: 8, left: 24),
        child: Text(
          l.editFileNoDiff,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            fontFamily: 'monospace',
          ),
        ),
      );
    }

    final diff = diffs[_selectedDiffIndex];

    return Padding(
      padding: const EdgeInsets.only(top: 8, left: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (diffs.length > 1) _buildDiffTabs(context, l, diffs),
          _buildPathHeader(context, l, diff),
          const SizedBox(height: 8),
          _buildViewToggle(context, l),
          const SizedBox(height: 8),
          _buildDiffBody(context, l, diff),
        ],
      ),
    );
  }

  Widget _buildDiffTabs(
    BuildContext context,
    AppLocalizations l,
    List<FileDiff> diffs,
  ) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: SizedBox(
        height: 28,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: diffs.length,
          separatorBuilder: (_, __) => const SizedBox(width: 6),
          itemBuilder: (context, i) {
            final selected = i == _selectedDiffIndex;
            return InkWell(
              onTap: () => setState(() => _selectedDiffIndex = i),
              borderRadius: BorderRadius.circular(4),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
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

  Widget _buildPathHeader(
    BuildContext context,
    AppLocalizations l,
    FileDiff diff,
  ) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.folder_outlined,
              size: 14, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              diff.path,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurface,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          _Badge(
            label: diff.oldText == null ? l.editFileNewFile : l.editFileModified,
            color: diff.oldText == null
                ? theme.colorScheme.tertiary
                : theme.colorScheme.primary,
          ),
          const SizedBox(width: 8),
          _CopyButton(
            label: l.editFileCopy,
            copiedLabel: l.editFileCopied,
            text: diff.newText,
            onCopied: () => setState(() {
              _copied = true;
              Future.delayed(const Duration(seconds: 2),
                  () => mounted ? setState(() => _copied = false) : null);
            }),
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
        ],
      ),
    );
  }

  Widget _buildViewToggle(BuildContext context, AppLocalizations l) {
    final theme = Theme.of(context);
    return Wrap(
      spacing: 4,
      children: [
        for (final v in _DiffView.values)
          ChoiceChip(
            label: Text(_viewLabel(v, l)),
            selected: _view == v,
            onSelected: (_) => setState(() => _view = v),
            visualDensity: VisualDensity.compact,
            labelStyle: theme.textTheme.labelSmall,
          ),
      ],
    );
  }

  String _viewLabel(_DiffView v, AppLocalizations l) => switch (v) {
        _DiffView.inline => l.editFileDiff,
        _DiffView.before => l.editFileBefore,
        _DiffView.after => l.editFileAfter,
      };

  Widget _buildDiffBody(
    BuildContext context,
    AppLocalizations l,
    FileDiff diff,
  ) {
    final theme = Theme.of(context);
    final splitter = const LineSplitter();
    final oldLines = diff.oldText == null
        ? const <String>[]
        : splitter.convert(diff.oldText!);
    final newLines = splitter.convert(diff.newText);

    if (diff.oldText == null) {
      return _DiffScrollArea(
        child: _LineGrid(lines: newLines, kind: _LineKind.added),
      );
    }

    final view = _view;
    if (view == _DiffView.before) {
      return _DiffScrollArea(
        child: _LineGrid(lines: oldLines, kind: _LineKind.context),
      );
    }
    if (view == _DiffView.after) {
      return _DiffScrollArea(
        child: _LineGrid(lines: newLines, kind: _LineKind.context),
      );
    }

    final hunks = _computeUnifiedDiff(oldLines, newLines);
    return _DiffScrollArea(child: _UnifiedDiffView(hunks: hunks));
  }

  String _basename(String path) {
    if (path.isEmpty) return path;
    if (path.contains('\\')) {
      return p.Context(style: p.Style.windows).basename(path);
    }
    return p.basename(path);
  }
}

enum _DiffView { inline, before, after }

enum _LineKind { context, added, removed }

class _DiffScrollArea extends StatelessWidget {
  final Widget child;
  const _DiffScrollArea({required this.child});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 360),
      child: SingleChildScrollView(
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(6),
          ),
          child: child,
        ),
      ),
    );
  }
}

class _LineGrid extends StatelessWidget {
  final List<String> lines;
  final _LineKind kind;
  const _LineGrid({required this.lines, required this.kind});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (marker, color) = switch (kind) {
      _LineKind.added => ('+', theme.colorScheme.primary),
      _LineKind.removed => ('-', theme.colorScheme.error),
      _LineKind.context => (' ', theme.colorScheme.onSurface),
    };
    return DefaultTextStyle(
      style: theme.textTheme.bodySmall!.copyWith(
        color: theme.colorScheme.onSurface,
        fontFamily: 'monospace',
        height: 1.4,
      ),
      child: lines.isEmpty
          ? Text(
              ' ',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontFamily: 'monospace',
              ),
            )
          : SelectableText(
              lines.map((l) => '$marker $l').join('\n'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: color,
                fontFamily: 'monospace',
                height: 1.4,
              ),
            ),
    );
  }
}

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
              theme.colorScheme.primaryContainer.withValues(alpha: 0.25),
            ),
          _LineKind.removed => (
              '-',
              theme.colorScheme.error,
              theme.colorScheme.errorContainer.withValues(alpha: 0.25),
            ),
          _LineKind.context => (
              ' ',
              theme.colorScheme.onSurface,
              Colors.transparent,
            ),
        };
        rows.add(Container(
          color: bg,
          padding: const EdgeInsets.symmetric(horizontal: 4),
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
    if (rows.isEmpty) {
      return Text(
        ' ',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          fontFamily: 'monospace',
        ),
      );
    }
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

  // dp[i][j] = length of LCS of a[i..] and b[j..]
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

class _Badge extends StatelessWidget {
  final String label;
  final Color color;
  const _Badge({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(color: color),
      ),
    );
  }
}

class _CopyButton extends StatelessWidget {
  final String label;
  final String copiedLabel;
  final String text;
  final VoidCallback onCopied;
  const _CopyButton({
    required this.label,
    required this.copiedLabel,
    required this.text,
    required this.onCopied,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: () async {
        await Clipboard.setData(ClipboardData(text: text));
        onCopied();
      },
      borderRadius: BorderRadius.circular(4),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.copy_outlined,
                size: 12, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: 4),
            Text(
              label,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
