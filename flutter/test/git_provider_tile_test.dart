import 'package:devinorium_frontend/widgets/git_provider_icons.dart';
import 'package:devinorium_frontend/widgets/git_provider_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('GitProviderTile renders title, subtitle and icon', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: GitProviderTile(
            icon: GitLabIcon(),
            title: 'GitLab',
            subtitle: 'Connected as owner',
          ),
        ),
      ),
    );

    expect(find.text('GitLab'), findsOneWidget);
    expect(find.text('Connected as owner'), findsOneWidget);
    expect(find.byType(GitLabIcon), findsOneWidget);
  });

  testWidgets('GitProviderTile renders trailing and details', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GitProviderTile(
            icon: const GitHubIcon(),
            title: 'GitHub',
            subtitle: 'Coming soon',
            trailing: const Chip(label: Text('Soon')),
            details: const Text('More info'),
          ),
        ),
      ),
    );

    expect(find.text('GitHub'), findsOneWidget);
    expect(find.text('Coming soon'), findsOneWidget);
    expect(find.text('Soon'), findsOneWidget);
    expect(find.text('More info'), findsOneWidget);
    expect(find.byType(GitHubIcon), findsOneWidget);
  });

  testWidgets('GitProviderTile applies opacity', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: GitProviderTile(
            icon: GitLabIcon(),
            title: 'GitLab',
            opacity: 0.5,
          ),
        ),
      ),
    );

    final opacity = tester.widget<Opacity>(find.byType(Opacity));
    expect(opacity.opacity, 0.5);
  });
}
