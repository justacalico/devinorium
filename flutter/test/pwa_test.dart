import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

String? _attr(String tag, String name) =>
    RegExp('$name="([^"]*)"').firstMatch(tag)?.group(1);

void main() {
  final indexHtml = File('web/index.html').readAsStringSync();
  final linkTags = RegExp(r'<link\b[^>]*>')
      .allMatches(indexHtml)
      .map((m) => m.group(0)!)
      .toList();
  final splashHrefs = linkTags
      .where((t) => _attr(t, 'rel') == 'apple-touch-startup-image')
      .map((t) => _attr(t, 'href')!)
      .toList();

  test('manifest.json declares a standalone installable app', () {
    final manifest = jsonDecode(File('web/manifest.json').readAsStringSync())
        as Map<String, dynamic>;

    expect(manifest['name'], 'Devinorium');
    expect(manifest['short_name'], 'Devinorium');
    expect(manifest['id'], isNotNull);
    expect(manifest['scope'], isNotNull);
    expect(manifest['display'], 'standalone');
    expect(manifest['background_color'], startsWith('#'));
    expect(manifest['theme_color'], startsWith('#'));

    final icons = manifest['icons'] as List<dynamic>;
    expect(icons, isNotEmpty);
    for (final icon in icons) {
      final src = (icon as Map<String, dynamic>)['src'] as String;
      expect(
        File('web/$src').existsSync(),
        isTrue,
        reason: 'manifest icon $src is missing from web/',
      );
    }
  });

  test('index.html declares iOS standalone support', () {
    expect(indexHtml, contains('name="apple-mobile-web-app-capable"'));
    expect(indexHtml, contains('name="apple-mobile-web-app-title"'));
    expect(indexHtml, contains('rel="apple-touch-icon"'));
    expect(indexHtml, contains('rel="manifest"'));
    // The Flutter engine injects its own viewport meta at startup, so the
    // page must patch viewport-fit=cover in afterwards.
    expect(indexHtml, contains('viewport-fit=cover'));
  });

  test('every apple icon and splash link in index.html exists on disk', () {
    final hrefs = linkTags
        .where((t) => (_attr(t, 'rel') ?? '').startsWith('apple-touch-'))
        .map((t) => _attr(t, 'href')!)
        .toList();
    expect(hrefs, isNotEmpty);
    for (final href in hrefs) {
      expect(
        File('web/$href').existsSync(),
        isTrue,
        reason: '$href referenced by index.html is missing',
      );
    }
  });

  test('splash links and on-disk splash files are the same set', () {
    final linked = splashHrefs.map((h) => h.split('/').last).toSet();
    final onDisk = Directory('web/icons/splash')
        .listSync()
        .whereType<File>()
        .map((f) => f.uri.pathSegments.last)
        .toSet();
    expect(onDisk, linked);
  });

  test('splash media queries match the pixel size of each splash image', () {
    expect(splashHrefs, isNotEmpty);
    for (final tag in linkTags) {
      if (_attr(tag, 'rel') != 'apple-touch-startup-image') continue;
      final name = _attr(tag, 'href')!.split('/').last;
      final dims = RegExp(r'apple-splash-(\d+)x(\d+)\.png').firstMatch(name)!;
      final w = int.parse(dims.group(1)!);
      final h = int.parse(dims.group(2)!);
      final media = _attr(tag, 'media')!;

      final deviceW = int.parse(
        RegExp(r'device-width: (\d+)px').firstMatch(media)!.group(1)!,
      );
      final deviceH = int.parse(
        RegExp(r'device-height: (\d+)px').firstMatch(media)!.group(1)!,
      );
      final dpr = int.parse(
        RegExp(r'pixel-ratio: (\d+)').firstMatch(media)!.group(1)!,
      );
      final orientation = RegExp(r'orientation: (\w+)').firstMatch(media)!;

      // Apple always describes the device by its portrait dims in the media
      // query; the orientation flag selects between the two image variants.
      final landscape = orientation.group(1) == 'landscape';
      final expectedW = (landscape ? deviceH : deviceW) * dpr;
      final expectedH = (landscape ? deviceW : deviceH) * dpr;
      expect(
        w == expectedW && h == expectedH,
        isTrue,
        reason: '$name does not match its media query "$media"',
      );
      expect(landscape, w > h, reason: 'orientation mismatch for $name');
    }
  });

  test('splash PNG dimensions match the size in their filename', () {
    final splashDir = Directory('web/icons/splash');
    final files = splashDir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.png'))
        .toList();
    expect(files, isNotEmpty);
    for (final file in files) {
      final name = file.uri.pathSegments.last;
      final match = RegExp(r'apple-splash-(\d+)x(\d+)\.png').firstMatch(name);
      expect(match, isNotNull, reason: '$name is not a splash filename');
      final bytes = ByteData.sublistView(file.readAsBytesSync());
      // PNG IHDR width and height are big-endian u32s at byte offsets 16/20.
      expect(
        bytes.getUint32(16),
        int.parse(match!.group(1)!),
        reason: name,
      );
      expect(bytes.getUint32(20), int.parse(match.group(2)!), reason: name);
    }
  });
}
