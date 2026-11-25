import 'dart:js_interop';

@JS('window.open')
external JSAny? _open(String url, String target);

/// In the PC app the WebView turns this into the default browser.
Future<void> openLink(String url) async {
  _open(url, '_blank');
}
