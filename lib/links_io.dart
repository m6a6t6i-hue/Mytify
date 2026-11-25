import 'dart:io';

import 'package:flutter/services.dart';

Future<void> openLink(String url) async {
  if (Platform.isAndroid) {
    await const MethodChannel('pl.mytify/library').invokeMethod<void>('openUrl', {'url': url});
  } else if (Platform.isWindows) {
    await Process.start('rundll32.exe', ['url.dll,FileProtocolHandler', url]);
  } else if (Platform.isMacOS) {
    await Process.start('open', [url]);
  } else {
    await Process.start('xdg-open', [url]);
  }
}
