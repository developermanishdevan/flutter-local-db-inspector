import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:web/web.dart' as web;

import 'bridge.dart';

/// The built UI, copied into `web/web_ui/` by `tool/sync_web_ui.sh` and
/// served next to the extension (same origin).
const _src = 'web_ui/index.html';
const _modeKey = 'flutter_db_inspector.ui';

Widget buildWebUiFrame({
  required WebUiBridge Function(PostToWebUi post) createBridge,
  required Widget missing,
  required bool dark,
}) =>
    _WebUiFrame(createBridge: createBridge, missing: missing, dark: dark);

/// Shows the shared web UI in an iframe filling the extension and connects
/// it to a [WebUiBridge] through `postMessage`.
class _WebUiFrame extends StatefulWidget {
  const _WebUiFrame({
    required this.createBridge,
    required this.missing,
    required this.dark,
  });

  final WebUiBridge Function(PostToWebUi post) createBridge;
  final Widget missing;

  /// Theme for the first paint; later changes arrive as `theme` messages.
  final bool dark;

  @override
  State<_WebUiFrame> createState() => _WebUiFrameState();
}

class _WebUiFrameState extends State<_WebUiFrame> {
  web.HTMLIFrameElement? _iframe;
  WebUiBridge? _bridge;
  bool _missing = false;
  late final JSFunction _onMessage = _handleMessage.toJS;

  @override
  void initState() {
    super.initState();
    web.window.addEventListener('message', _onMessage);
  }

  @override
  void dispose() {
    web.window.removeEventListener('message', _onMessage);
    _bridge?.dispose();
    super.dispose();
  }

  void _created(Object element) {
    final iframe = element as web.HTMLIFrameElement
      ..src = '$_src?theme=${widget.dark ? 'dark' : 'light'}'
      ..title = 'Flutter DB Inspector';
    iframe.style
      ..border = 'none'
      ..width = '100%'
      ..height = '100%';
    iframe.addEventListener('load', ((web.Event _) => _checkLoaded()).toJS);
    _iframe = iframe;
    _bridge?.dispose();
    _bridge = widget.createBridge(_post);
  }

  /// Only messages from our iframe reach the bridge; DevTools' own messages
  /// (theme, VM service) go to the extension manager.
  void _handleMessage(web.Event event) {
    final frame = _iframe?.contentWindow;
    if (frame == null) return;
    final message = event as web.MessageEvent;
    if (!message.source.strictEquals(frame).toDart) return;
    _bridge?.handle(message.data.dartify());
  }

  void _post(Map<String, Object?> message) {
    // Same origin as this page; '*' only where the origin is opaque.
    final origin = web.window.location.origin;
    _iframe?.contentWindow?.postMessage(
      message.jsify(),
      (origin.isEmpty || origin == 'null' ? '*' : origin).toJS,
    );
  }

  /// A missing `web/web_ui/` (not synced before `flutter build web`) loads
  /// the server's error page instead of the UI.
  void _checkLoaded() {
    try {
      final doc = _iframe?.contentDocument;
      if (doc == null || !doc.URL.contains(_src)) return;
      if (doc.getElementById('app') == null && mounted) {
        setState(() => _missing = true);
      }
    } on Object {
      // Not readable: assume the UI is there.
    }
  }

  @override
  Widget build(BuildContext context) => _missing
      ? widget.missing
      : HtmlElementView.fromTagName(
          tagName: 'iframe',
          onElementCreated: _created,
        );
}

/// Saves [bytes] through a browser download from the extension's document.
void downloadFile(String name, Uint8List bytes) {
  final blob = web.Blob(
    <web.BlobPart>[bytes.toJS].toJS,
    web.BlobPropertyBag(type: 'application/octet-stream'),
  );
  final url = web.URL.createObjectURL(blob);
  final anchor = web.HTMLAnchorElement()
    ..href = url
    ..download = name;
  anchor.style.display = 'none';
  web.document.body?.append(anchor);
  anchor
    ..click()
    ..remove();
  Timer(const Duration(minutes: 1), () => web.URL.revokeObjectURL(url));
}

/// `?ui=classic|web` in the extension URL, else the last choice.
String? readUiMode() {
  final query = Uri.base.queryParameters['ui'];
  if (query != null) return query;
  try {
    return web.window.localStorage.getItem(_modeKey);
  } on Object {
    return null;
  }
}

void writeUiMode(String mode) {
  try {
    web.window.localStorage.setItem(_modeKey, mode);
  } on Object {
    // Storage blocked: the choice lasts for this page load.
  }
}
