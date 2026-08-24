import 'package:devinorium_frontend/widgets/git_provider_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('GitHubIcon renders an SvgPicture', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: GitHubIcon()));
    expect(find.byType(GitHubIcon), findsOneWidget);
    expect(find.byType(SvgPicture), findsOneWidget);
  });

  testWidgets('GitHubIcon applies a custom color', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: GitHubIcon(color: Colors.red),
      ),
    );
    expect(find.byType(SvgPicture), findsOneWidget);
  });

  testWidgets('GitLabIcon renders an SvgPicture', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: GitLabIcon()));
    expect(find.byType(GitLabIcon), findsOneWidget);
    expect(find.byType(SvgPicture), findsOneWidget);
  });

  testWidgets('GitLabIcon can be recolored', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: GitLabIcon(color: Colors.green),
      ),
    );
    expect(find.byType(SvgPicture), findsOneWidget);
  });

  testWidgets('GitLabIcon uses brand colors when no color is passed', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: GitLabIcon()));
    final svg = tester.widget<SvgPicture>(find.byType(SvgPicture));
    expect(svg.colorFilter, isNull);
  });
}
