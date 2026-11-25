import 'links_io.dart' if (dart.library.js_interop) 'links_web.dart' as platform;

/// Opens a web page in the system browser.
Future<void> openLink(String url) => platform.openLink(url);
