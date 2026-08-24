import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

class GitHubIcon extends StatelessWidget {
  final Color? color;
  final double size;
  final String? semanticsLabel;

  const GitHubIcon({
    super.key,
    this.color,
    this.size = 24,
    this.semanticsLabel = 'GitHub',
  });

  @override
  Widget build(BuildContext context) {
    final effectiveColor = color ?? Theme.of(context).colorScheme.onSurface;
    return SvgPicture.string(
      _svg,
      width: size,
      height: size,
      colorFilter: ColorFilter.mode(effectiveColor, BlendMode.srcIn),
      semanticsLabel: semanticsLabel,
    );
  }

  static const String _svg = '''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" fill="none">
  <path
    fill-rule="evenodd"
    clip-rule="evenodd"
    d="M8 0C3.58 0 0 3.58 0 8C0 11.54 2.29 14.53 5.47 15.59C5.87 15.66 6.02 15.42 6.02 15.21C6.02 15.02 6.01 14.39 6.01 13.72C4 14.09 3.48 13.23 3.32 12.78C3.23 12.55 2.84 11.84 2.5 11.65C2.22 11.5 1.82 11.13 2.49 11.12C3.12 11.11 3.57 11.7 3.72 11.94C4.44 13.15 5.59 12.81 6.05 12.6C6.12 12.08 6.33 11.73 6.56 11.53C4.78 11.33 2.92 10.64 2.92 7.58C2.92 6.71 3.23 5.99 3.74 5.43C3.66 5.23 3.38 4.41 3.82 3.31C3.82 3.31 4.49 3.1 6.02 4.13C6.66 3.95 7.34 3.86 8.02 3.86C8.7 3.86 9.38 3.95 10.02 4.13C11.55 3.09 12.22 3.31 12.22 3.31C12.66 4.41 12.38 5.23 12.3 5.43C12.81 5.99 13.12 6.7 13.12 7.58C13.12 10.65 11.25 11.33 9.47 11.53C9.76 11.78 10.01 12.26 10.01 13.01C10.01 14.08 10 14.94 10 15.21C10 15.42 10.15 15.67 10.55 15.59C13.71 14.53 16 11.53 16 8C16 3.58 12.42 0 8 0Z"
    fill="currentColor"
  />
</svg>''';
}

/// The GitLab icon in its brand colors.
///
/// When [color] is provided, the icon is tinted with that color; otherwise
/// the original orange/red brand palette from the SVG is used.
class GitLabIcon extends StatelessWidget {
  final Color? color;
  final double size;
  final String? semanticsLabel;

  const GitLabIcon({
    super.key,
    this.color,
    this.size = 24,
    this.semanticsLabel = 'GitLab',
  });

  @override
  Widget build(BuildContext context) {
    final colorFilter =
        color == null ? null : ColorFilter.mode(color!, BlendMode.srcIn);
    return SvgPicture.string(
      _svg,
      width: size,
      height: size,
      colorFilter: colorFilter,
      semanticsLabel: semanticsLabel,
    );
  }

  static const String _svg = '''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32" fill="none">
  <path
    d="m31.46 12.78-.04-.12-4.35-11.35A1.14 1.14 0 0 0 25.94.6c-.24 0-.47.1-.66.24-.19.15-.33.36-.39.6l-2.94 9h-11.9l-2.94-9A1.14 1.14 0 0 0 6.07.58a1.15 1.15 0 0 0-1.14.72L.58 12.68l-.05.11a8.1 8.1 0 0 0 2.68 9.34l.02.01.04.03 6.63 4.97 3.28 2.48 2 1.52a1.35 1.35 0 0 0 1.62 0l2-1.52 3.28-2.48 6.67-5h.02a8.09 8.09 0 0 0 2.7-9.36Z"
    fill="#E24329"
  />
  <path
    d="m31.46 12.78-.04-.12a14.75 14.75 0 0 0-5.86 2.64l-9.55 7.24 6.09 4.6 6.67-5h.02a8.09 8.09 0 0 0 2.67-9.36Z"
    fill="#FC6D26"
  />
  <path
    d="m9.9 27.14 3.28 2.48 2 1.52a1.35 1.35 0 0 0 1.62 0l2-1.52 3.28-2.48-6.1-4.6-6.07 4.6Z"
    fill="#FCA326"
  />
  <path
    d="M6.44 15.3a14.71 14.71 0 0 0-5.86-2.63l-.05.12a8.1 8.1 0 0 0 2.68 9.34l.02.01.04.03 6.63 4.97 6.1-4.6-9.56-7.24Z"
    fill="#FC6D26"
  />
</svg>''';
}
