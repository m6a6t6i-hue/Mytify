import 'dart:io';

/// Running under `flutter test`: endless animations stay still so tests can settle.
bool get inFlutterTest => Platform.environment.containsKey('FLUTTER_TEST');
