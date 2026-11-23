/// Turning a workspace HTML file into something safe to hand to a WebView.
///
/// The file is untrusted: it may come from the agent, from a repository, or from
/// something the user downloaded. Three rules, in order of importance:
///
/// 1. **Nothing loads from the network.** A page that can fetch a URL can tell a
///    third party what the user is looking at, and can pull in remote script.
///    A `Content-Security-Policy` with `default-src 'none'` is the hard stop;
///    remote `<link>`, `<img>`, `<script>` and `@import` all fail closed.
/// 2. **Nothing executes.** `<script>`, inline handlers and `javascript:` URLs
///    are stripped here, and the WebView itself is created with JavaScript
///    disabled — the strip is defence in depth, not the only line.
/// 3. **Nothing navigates.** The preview blocks every navigation; links do not
///    leave the page (the viewer offers "open elsewhere" instead).
///
/// What survives: the document's own markup, inline `<style>`, `data:` images,
/// inline SVG, and `#fragment` anchors. That covers the shapes people actually
/// preview — a generated report, a saved page, a local dashboard — without the
/// page ever being able to talk to anything.
library;

/// Inline styles stay: a preview without CSS is not a preview.
const _csp =
    "default-src 'none'; img-src data:; style-src 'unsafe-inline'; "
    "font-src data:; media-src data:; form-action 'none'; base-uri 'none'; "
    "frame-ancestors 'none'";

/// Scripts and anything that can load or execute another document.
final _blockedBlocks = RegExp(
  r'''<\s*(script|iframe|frame|frameset|object|embed|applet|template|link)\b(?:[^>"']|"[^"]*"|'[^']*')*>\s*(?:.*?<\s*/\s*\1\s*>)?''',
  caseSensitive: false,
  dotAll: true,
);

/// `<meta http-equiv="refresh">` is a navigation the CSP does not cover.
final _metaRefresh = RegExp(
  r'''<\s*meta\b[^>]*http-equiv\s*=\s*["']?\s*refresh[^>]*>''',
  caseSensitive: false,
);

/// `onclick="…"`, `onload=…` and friends.
final _eventHandler = RegExp(
  r'''\son[a-z]+\s*=\s*("[^"]*"|'[^']*'|[^\s>]+)''',
  caseSensitive: false,
);

/// `href="javascript:…"` and `src="javascript:…"`.
final _javascriptUrl = RegExp(
  r'''((?:href|src|action)\s*=\s*)("javascript:[^"]*"|'javascript:[^']*'|javascript:[^\s>]+)''',
  caseSensitive: false,
);

/// `url(http://…)` inside styles or `style="…"`.
final _remoteUrl = RegExp(
  r'''url\(\s*['"]?(?:https?:)?//[^)]*\)''',
  caseSensitive: false,
);

/// Elements whose `src`/`href` would hit the network; the CSP blocks them, but
/// dropping the attribute keeps the layout from waiting on a doomed request.
final _remoteSrc = RegExp(
  r'''\s(src|srcset|href|poster|data)\s*=\s*("[^"]*(?:https?:)?//[^"]*"|'[^']*(?:https?:)?//[^']*')''',
  caseSensitive: false,
);

/// [source] with the dangerous parts removed and a locking CSP injected.
///
/// The result is still untrusted markup — it is the WebView's job to render it
/// without scripts and without network. This function only makes sure there is
/// nothing obvious left to render *with*.
String sanitizeHtmlForPreview(String source) {
  var html = source;

  // A UTF-16 BOM or a stray NUL is enough to make the parser give up.
  if (html.startsWith('\uFEFF')) html = html.substring(1);
  html = html.replaceAll('\u0000', '');

  html = html.replaceAll(_blockedBlocks, '');
  html = html.replaceAll(_metaRefresh, '');
  html = html.replaceAll(_javascriptUrl, r'$1"#"');
  html = html.replaceAll(_eventHandler, '');
  html = html.replaceAll(_remoteUrl, 'url(about:blank)');
  html = html.replaceAll(_remoteSrc, '');

  return _injectHead(html);
}

/// Puts the CSP and a charset in front of whatever the document has.
String _injectHead(String html) {
  const head = '<meta charset="utf-8">'
      '<meta http-equiv="Content-Security-Policy" content="$_csp">'
      '<meta name="referrer" content="no-referrer">'
      '<meta name="viewport" content="width=device-width, initial-scale=1">';

  final lower = html.toLowerCase();
  final headOpen = lower.indexOf('<head');
  if (headOpen >= 0) {
    final close = lower.indexOf('>', headOpen);
    if (close >= 0) return html.replaceRange(close + 1, close + 1, head);
  }
  final htmlOpen = lower.indexOf('<html');
  if (htmlOpen >= 0) {
    final close = lower.indexOf('>', htmlOpen);
    if (close >= 0) return html.replaceRange(close + 1, close + 1, '<head>$head</head>');
  }
  return '<head>$head</head>$html';
}

/// Whether [source] is a complete document or a fragment.
///
/// A fragment (a snippet the agent pasted) still has to be wrapped, or the
/// browser applies quirks mode and the preview looks nothing like the real page.
bool looksLikeFragment(String source) {
  final lower = source.toLowerCase();
  return !lower.contains('<html') && !lower.contains('<!doctype');
}
