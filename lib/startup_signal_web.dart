import 'dart:js_interop';

@JS('mytifyReady')
external JSFunction? get _ready;

/// PC: the intro in index.html stays until the library is loaded and the NAS answered.
void signalStartupDone() {
  try {
    _ready?.callAsFunction();
  } catch (_) {}
}
