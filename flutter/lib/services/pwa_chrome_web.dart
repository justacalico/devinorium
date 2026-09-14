import 'package:web/web.dart' as web;

/// Applies the resolved app theme to the surrounding page chrome.
///
/// The media attributes on the static `theme-color` tags are removed so the
/// in-app theme beats `prefers-color-scheme`; document order makes the first
/// matching tag win, so every tag is rewritten to the same color.
void syncPwaChromeImpl(String hexColor, bool dark) {
  try {
    _apply(hexColor, dark);
  } catch (_) {}
}

void _apply(String hexColor, bool dark) {
  final head = web.document.head;
  if (head == null) return;

  var metas = web.document.querySelectorAll('meta[name="theme-color"]');
  if (metas.length == 0) {
    head.appendChild(
      web.document.createElement('meta')..setAttribute('name', 'theme-color'),
    );
    metas = web.document.querySelectorAll('meta[name="theme-color"]');
  }
  for (var i = 0; i < metas.length; i++) {
    final meta = metas.item(i) as web.Element?;
    meta
      ?..setAttribute('content', hexColor)
      ..removeAttribute('media');
  }

  final root = web.document.documentElement as web.HTMLElement?;
  root?.style
    ?..setProperty('background-color', hexColor)
    ..setProperty('color-scheme', dark ? 'dark' : 'light');
  web.document.body?.style.setProperty('background-color', hexColor);
}
