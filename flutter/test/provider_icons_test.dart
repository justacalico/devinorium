import 'package:devinorium_frontend/widgets/provider_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _wrap(Widget child, {Brightness brightness = Brightness.light}) {
  return MaterialApp(
    theme: ThemeData(brightness: brightness),
    home: Scaffold(body: Center(child: child)),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('provider logo assets', () {
    for (final path in [
      'assets/providers/devin.png',
      'assets/providers/devin_light.png',
      'assets/providers/opencode.svg',
      'assets/providers/codex.svg',
    ]) {
      test('$path is bundled and non-empty', () async {
        final data = await rootBundle.load(path);
        expect(data.lengthInBytes, greaterThan(0));
      });
    }
  });

  testWidgets('devin-cli renders the dark logo in a light theme', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(const ProviderIcon(providerId: 'devin-cli')),
    );
    final image = tester.widget<Image>(find.byType(Image));
    expect((image.image as AssetImage).assetName, 'assets/providers/devin.png');
  });

  testWidgets('devin-cli renders the light logo in a dark theme', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        const ProviderIcon(providerId: 'devin-cli'),
        brightness: Brightness.dark,
      ),
    );
    final image = tester.widget<Image>(find.byType(Image));
    expect(
      (image.image as AssetImage).assetName,
      'assets/providers/devin_light.png',
    );
  });

  testWidgets('opencode renders its SVG badge with rounded corners', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(const ProviderIcon(providerId: 'opencode')),
    );
    expect(find.byType(ClipRRect), findsOneWidget);
    expect(find.byType(SvgPicture), findsOneWidget);
  });

  testWidgets('codex renders a tinted SVG', (tester) async {
    await tester.pumpWidget(
      _wrap(const ProviderIcon(providerId: 'codex', color: Colors.red)),
    );
    final svg = tester.widget<SvgPicture>(find.byType(SvgPicture));
    expect(svg.colorFilter, isNotNull);
  });

  testWidgets('unknown providers fall back to a generic icon', (tester) async {
    await tester.pumpWidget(
      _wrap(const ProviderIcon(providerId: 'future-cli')),
    );
    final icon = tester.widget<Icon>(find.byType(Icon));
    expect(icon.icon, Icons.smart_toy_outlined);
  });

  testWidgets('ProviderIcon applies a semantic label', (tester) async {
    await tester.pumpWidget(
      _wrap(
        const ProviderIcon(
          providerId: 'codex',
          semanticLabel: 'Codex CLI',
        ),
      ),
    );
    final handle = tester.ensureSemantics();
    expect(find.bySemanticsLabel('Codex CLI'), findsOneWidget);
    handle.dispose();
  });

  test('providerName maps known ids and falls back to the id', () {
    expect(providerName('devin-cli'), 'Devin CLI');
    expect(providerName('opencode'), 'OpenCode');
    expect(providerName('codex'), 'Codex CLI');
    expect(providerName('unknown'), 'unknown');
  });
}
