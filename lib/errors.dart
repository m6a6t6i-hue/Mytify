import 'package:material_ui/material_ui.dart';

import 'l10n.dart';

/// Where UI errors go (the core's error log on PC). Set once the library is up.
void Function(String text)? uiErrorSink;

final _sent = <String>{};

/// Records an error once (a broken build repeats every frame).
void reportUiError(Object error, StackTrace? stack) {
  final head = '$error'.split('\n').first;
  if (_sent.contains(head) || _sent.length > 50) return;
  _sent.add(head);
  final text = [
    '$error',
    if (stack != null) stack.toString().split('\n').take(25).join('\n'),
  ].join('\n');
  try {
    uiErrorSink?.call(text);
  } catch (_) {}
}

/// Errors are visible and logged instead of a grey box: the view says what broke and
/// the rest of the app keeps working.
void installErrorHandling() {
  final previous = FlutterError.onError;
  FlutterError.onError = (details) {
    previous?.call(details);
    reportUiError(details.exception, details.stack);
  };
  WidgetsBinding.instance.platformDispatcher.onError = (error, stack) {
    reportUiError(error, stack);
    return true;
  };
  ErrorWidget.builder = (details) => BrokenView(details.exceptionAsString());
}

class BrokenView extends StatelessWidget {
  final String error;
  const BrokenView(this.error, {super.key});

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      const red = Color(0xFFE5534B);
      // A tiny slot (a row, an icon): only a mark, so nothing else overflows.
      if (box.maxWidth < 220 || box.maxHeight < 120) {
        return const ColoredBox(color: Color(0x33E5534B), child: SizedBox.expand());
      }
      return Material(
        type: MaterialType.transparency,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.error_outline_rounded, color: red, size: 36),
                    const SizedBox(height: 12),
                    Text(
                      tr('Ten widok się nie wyświetlił'),
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: Color(0xFFEDEDED)),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      tr('Przejdź do innego widoku i wróć. Błąd jest zapisany w mytify-errors.log.'),
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 13, color: Color(0xFFA0A0A0)),
                    ),
                    const SizedBox(height: 12),
                    SelectableText(
                      error.length > 600 ? '${error.substring(0, 600)}…' : error,
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 12, fontFamily: 'monospace', color: Color(0xFFB8B8B8)),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}

/// Disposes controllers after the frame that still shows them.
void disposeLater(Iterable<ChangeNotifier> items) {
  final list = items.toList();
  if (list.isEmpty) return;
  void now() {
    for (final c in list) {
      c.dispose();
    }
  }

  final WidgetsBinding binding;
  try {
    binding = WidgetsBinding.instance;
  } catch (_) {
    return now(); // no UI (plain unit test)
  }
  binding.addPostFrameCallback((_) => now());
  binding.scheduleFrame();
}
