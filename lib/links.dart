import 'links_io.dart' if (dart.library.js_interop) 'links_web.dart' as platform;

/// Opens a web page in the system browser. [browser] keeps store apps (Bandcamp, Qobuz)
/// from taking over the link: their apps open on the home screen and drop the search.
Future<void> openLink(String url, {bool browser = false}) => platform.openLink(url, browser: browser);
