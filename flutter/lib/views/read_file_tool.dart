import 'dart:convert';

import 'package:devinorium_frontend/l10n/l10n.dart';
import 'package:devinorium_frontend/models/models.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

/// Parsed metadata from a `read` tool call.
class ReadToolInfo {
  final String filePath;
  final String fileName;
  final int? startLine;
  final int? endLine;
  final int lineCount;
  final String content;
  final List<String> lines;

  const ReadToolInfo({
    required this.filePath,
    required this.fileName,
    this.startLine,
    this.endLine,
    required this.lineCount,
    required this.content,
    required this.lines,
  });
}

/// Parses a [ToolCallData] into [ReadToolInfo] if it is a read call.
ReadToolInfo? parseReadTool(ToolCallData tool) {
  if (tool.kind != 'read') return null;

  final command = tool.command;
  if (command == null || command.isEmpty) return null;

  String? filePath;
  int? startLine;
  int? endLine;

  try {
    final decoded = jsonDecode(command) as Map<String, dynamic>?;
    if (decoded != null) {
      filePath = decoded['file_path'] as String?;
      startLine = _parseInt(decoded['start_line']);
      endLine = _parseInt(decoded['end_line']);
    }
  } catch (_) {
    // Fall back to treating the command as the raw path.
    filePath = command;
  }

  if (filePath == null || filePath.isEmpty) return null;

  final String content;
  final int lineCount;
  if (tool.output != null && tool.output!.isNotEmpty) {
    content = tool.output!;
    final lines = const LineSplitter().convert(content);
    lineCount = lines.length;
  } else if (tool.outputPreview != null && tool.outputPreview!.isNotEmpty) {
    content = tool.outputPreview!;
    lineCount = _tryParseLineCount(tool.outputPreview);
  } else {
    content = '';
    lineCount = 0;
  }

  final fileName = p.Context(style: p.Style.windows).basename(filePath);

  return ReadToolInfo(
    filePath: filePath,
    fileName: fileName,
    startLine: startLine,
    endLine: endLine,
    lineCount: lineCount,
    content: content,
    lines: const LineSplitter().convert(content),
  );
}

int? _parseInt(dynamic v) {
  if (v == null) return null;
  if (v is int) return v;
  if (v is String) return int.tryParse(v);
  return null;
}

int _tryParseLineCount(String? text) {
  if (text == null) return 0;
  final match = RegExp(r'(\d+)\s*lines?', caseSensitive: false).firstMatch(text);
  if (match != null) {
    return int.tryParse(match.group(1)!) ?? 0;
  }
  return 0;
}

/// A styled tool-call card for the `read` kind.
class ReadFileTool extends StatefulWidget {
  final ToolCallData tool;
  const ReadFileTool({super.key, required this.tool});

  @override
  State<ReadFileTool> createState() => _ReadFileToolState();
}

class _ReadFileToolState extends State<ReadFileTool> {
  bool _expanded = false;
  ReadToolInfo? _info;

  @override
  void initState() {
    super.initState();
    _info = parseReadTool(widget.tool);
  }

  @override
  void didUpdateWidget(covariant ReadFileTool oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.tool.id != oldWidget.tool.id ||
        widget.tool.status != oldWidget.tool.status ||
        widget.tool.output != oldWidget.tool.output) {
      _info = parseReadTool(widget.tool);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l = l10n(context);
    final info = _info;
    if (info == null) return const SizedBox.shrink();

    final statusColor = switch (widget.tool.status) {
      'completed' => theme.colorScheme.primary,
      'failed' => theme.colorScheme.error,
      _ => theme.colorScheme.onSurfaceVariant,
    };

    final statusIcon = switch (widget.tool.status) {
      'completed' => Icons.check,
      'failed' => Icons.error_outline,
      _ => Icons.play_circle_outline,
    };

    final lineCountText = l.readFileLineCount(info.lineCount);
    final lineRange = info.startLine != null && info.endLine != null
        ? l.readFileLineRange(info.startLine!, info.endLine!)
        : lineCountText;

    return Semantics(
      button: true,
      expanded: _expanded,
      label: l.readFileTitle(info.fileName),
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
                  Icon(Icons.file_open_outlined,
                      size: 16, color: theme.colorScheme.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      l.readFileTitle(info.fileName),
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurface,
                        fontWeight: FontWeight.w500,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Text(
                    lineCountText,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Icon(statusIcon, size: 14, color: statusColor),
                  const SizedBox(width: 4),
                  Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    size: 14,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ],
              ),
              if (_expanded) _buildExpanded(context, info, lineRange, l),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildExpanded(
    BuildContext context,
    ReadToolInfo info,
    String lineRange,
    AppLocalizations l,
  ) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.only(top: 8, left: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
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
                    info.filePath,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurface,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  lineRange,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 300),
            child: SingleChildScrollView(
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: info.lines.isEmpty
                    ? Text(
                        l.readFileNoContent,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                          fontFamily: 'monospace',
                        ),
                      )
                    : _CodeBlock(lines: info.lines),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CodeBlock extends StatelessWidget {
  final List<String> lines;
  const _CodeBlock({required this.lines});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    const lineNumberWidth = 40.0;

    return DefaultTextStyle(
      style: theme.textTheme.bodySmall!.copyWith(
        color: theme.colorScheme.onSurface,
        fontFamily: 'monospace',
        height: 1.4,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: lineNumberWidth,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (var i = 0; i < lines.length; i++)
                  Text(
                    '${i + 1}',
                    style: TextStyle(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: SelectableText(
              lines.join('\n'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurface,
                fontFamily: 'monospace',
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
