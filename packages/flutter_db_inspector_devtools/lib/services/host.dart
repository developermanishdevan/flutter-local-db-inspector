import 'package:flutter/services.dart';

/// What the extension needs from its host (DevTools, or a plain window in
/// tests): clipboard and notifications.
abstract interface class InspectorHost {
  /// Copies [text]; [what] describes it for the confirmation ("row as JSON").
  void copyToClipboard(String text, {String what = 'value'});

  /// Shows a short, non-blocking message.
  void notify(String message);
}

/// Uses Flutter's clipboard directly. DevTools hosts use the extension
/// manager instead (see `main.dart`), which also works inside IDE web views.
class ClipboardHost implements InspectorHost {
  const ClipboardHost();

  @override
  void copyToClipboard(String text, {String what = 'value'}) {
    Clipboard.setData(ClipboardData(text: text));
  }

  @override
  void notify(String message) {}
}
