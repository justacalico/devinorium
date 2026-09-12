part of '../settings_page.dart';

/// Owner-only audit log viewer. Pages through `GET /api/audit` newest-first.
class _AuditSection extends StatefulWidget {
  final AppState state;

  const _AuditSection({required this.state});

  @override
  State<_AuditSection> createState() => _AuditSectionState();
}

class _AuditSectionState extends State<_AuditSection> {
  static const _pageSize = 50;

  final List<AuditEntry> _entries = [];
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await widget.state.api.listAudit(limit: _pageSize);
      if (!mounted) return;
      setState(() {
        _entries
          ..clear()
          ..addAll(page);
        _hasMore = page.length == _pageSize;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore) return;
    setState(() => _loadingMore = true);
    try {
      final page = await widget.state.api.listAudit(
        limit: _pageSize,
        offset: _entries.length,
      );
      if (!mounted) return;
      setState(() {
        _entries.addAll(page);
        _hasMore = page.length == _pageSize;
        _loadingMore = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loadingMore = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l = l10n(context);

    return _SectionCard(
      title: l.auditLog,
      titleBadge: const OwnerBadge(),
      children: [
        Text(
          l.auditLogDescription,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 16),
        if (_loading)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (_error != null && _entries.isEmpty)
          _UsageError(label: l.auditLogLoadFailed, onRetry: _load)
        else if (_entries.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(
              l.auditLogEmpty,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          )
        else ...[
          ListView.separated(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: _entries.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (_, i) => _AuditRow(entry: _entries[i]),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                l.auditLogLoadFailed,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ),
          if (_hasMore)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Center(
                child: _loadingMore
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : TextButton(
                        onPressed: _loadMore,
                        child: Text(l.auditLogLoadMore),
                      ),
              ),
            ),
        ],
      ],
    );
  }
}

class _AuditRow extends StatelessWidget {
  final AuditEntry entry;

  const _AuditRow({required this.entry});

  String _localTime(String iso) {
    final dt = DateTime.tryParse(iso)?.toLocal();
    if (dt == null) return iso;
    String two(int v) => v.toString().padLeft(2, '0');
    return '${dt.year}-${two(dt.month)}-${two(dt.day)} '
        '${two(dt.hour)}:${two(dt.minute)}:${two(dt.second)}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l = l10n(context);
    final detailText = entry.detail.isEmpty ? '' : jsonEncode(entry.detail);
    final subtitle = StringBuffer(entry.username ?? l.auditLogSystem);
    if (detailText.isNotEmpty) subtitle.write(' · $detailText');
    if (entry.ipHash != null) subtitle.write(' · ip:${entry.ipHash}');

    return Tooltip(
      message: subtitle.toString(),
      waitDuration: const Duration(milliseconds: 400),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    entry.action,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  _localTime(entry.createdAt),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontFamily: 'monospace',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              subtitle.toString(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
