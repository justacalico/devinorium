part of '../settings_page.dart';

class _SectionCard extends StatelessWidget {
  final String title;
  final List<Widget> children;
  final Widget? titleBadge;
  const _SectionCard({
    required this.title,
    required this.children,
    this.titleBadge,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      elevation: 1,
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(title,
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w600)),
                if (titleBadge != null) ...[
                  const SizedBox(width: 8),
                  titleBadge!,
                ],
              ],
            ),
            const SizedBox(height: 16),
            ...children,
          ],
        ),
      ),
    );
  }
}
