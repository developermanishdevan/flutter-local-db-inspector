import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_db_inspector_client/flutter_db_inspector_client.dart';

/// Sends one message to the shared web UI (`window.postMessage` on the
/// iframe in DevTools; a list in tests).
typedef PostToWebUi = void Function(Map<String, Object?> message);

/// What the web UI asks of its host besides protocol calls.
abstract interface class WebUiServices {
  /// Writes [text] to the clipboard; [label] describes it ("row as JSON").
  void copy(String text, {String? label});

  /// Lets the user save [bytes] as a file suggested as [name].
  void saveFile(String name, Uint8List bytes);

  /// Shows a short, non-blocking message (`level`: info, warning, error).
  void notify(String message, {String? level});

  /// Records an error reported by the UI.
  void log(String message);
}

/// The DevTools side of the shared web UI's app-mode contract
/// (`shared/web-ui/README.md`, `messages.ts` in the VS Code extension).
///
/// Free of DOM code: the iframe widget feeds [handle] with messages from the
/// UI and delivers what [post] sends, so the dispatch is unit-testable.
///
/// * `ready` → `init {view: 'app', host: 'devtools', pageSize, theme}`, then
///   the current `connection`;
/// * connection changes → `connection {state, message}`;
/// * `flutter_db_inspector.databasesChanged` → `event {name}`;
/// * DevTools theme changes → `theme {theme}`;
/// * `request {id, request}` → `result {id, ok, result | error}`.
class WebUiBridge {
  WebUiBridge({
    required this.post,
    required this.sender,
    required this.connection,
    required Stream<void> databasesChanged,
    required this.darkTheme,
    required this.services,
    this.pageSize = defaultPageSize,
  }) {
    connection.addListener(_onConnection);
    darkTheme.addListener(_onTheme);
    _databasesSubscription = databasesChanged.listen((_) => _onDatabases());
  }

  /// Rows per page until the user picks another size.
  static const defaultPageSize = 50;

  final PostToWebUi post;
  final InspectorRequestSender sender;
  final ValueListenable<ConnectionSnapshot> connection;
  final ValueListenable<bool> darkTheme;
  final WebUiServices services;
  final int pageSize;

  late final StreamSubscription<void> _databasesSubscription;
  bool _ready = false;
  bool _disposed = false;

  /// Set while a change to `connected` is being delivered: the connection
  /// also fires `databasesChanged` right after (re)connecting, and the UI
  /// already reloads everything on `connected`.
  bool _justConnected = false;

  /// Handles one message from the UI. Anything that is not a UI message is
  /// ignored.
  void handle(Object? data) {
    if (_disposed || data is! Map) return;
    switch (data['type']) {
      case 'ready':
        // Also after the page reloads itself: start it over.
        _ready = true;
        _send({
          'type': 'init',
          'view': 'app',
          'host': 'devtools',
          'pageSize': pageSize,
          'theme': _theme,
        });
        _sendConnection();
      case 'error':
        services.log('Flutter DB Inspector UI: ${data['message']}');
      case 'request':
        final id = data['id'];
        final request = data['request'];
        if (id is! num) return;
        unawaited(_answer(id, request is Map ? request : const {}));
    }
  }

  Future<void> _answer(num id, Map<Object?, Object?> request) async {
    Map<String, Object?> reply;
    try {
      reply = {'ok': true, 'result': await _run(request)};
    } on InspectorClientException catch (e) {
      reply = {
        'ok': false,
        'error': {
          'code': e.code,
          'message': e.message,
          if (e.details.isNotEmpty) 'details': e.details,
        },
      };
    } on Object catch (e) {
      reply = {
        'ok': false,
        'error': {'code': ErrorCodes.internalError, 'message': '$e'},
      };
    }
    _send({'type': 'result', 'id': id, ...reply});
  }

  Future<Object?> _run(Map<Object?, Object?> request) async {
    final op = request['op'];
    switch (op) {
      case 'call':
        final method = request['method'];
        final params = request['params'] ?? const <String, Object?>{};
        if (method is! String || params is! Map) {
          throw const InspectorClientException(
            ErrorCodes.invalidRequest,
            'call needs a method name and a params object.',
          );
        }
        // Reads that race a hot restart are retried by the connection.
        return sender.request(method, params.cast<String, Object?>());
      case 'copy':
        final text = request['text'];
        if (text is! String) throw _invalid('copy needs text.');
        services.copy(text, label: request['label'] as String?);
        return const <String, Object?>{};
      case 'saveFile':
        final name = request['name'];
        final text = request['text'];
        final base64 = request['base64'];
        if (name is! String || (text is! String && base64 is! String)) {
          throw _invalid('saveFile needs a name and text or base64.');
        }
        final Uint8List bytes;
        try {
          bytes = text is String
              ? utf8.encode(text)
              : base64Decode(base64 as String);
        } on FormatException {
          throw _invalid('saveFile: base64 content is malformed.');
        }
        // A browser download cannot be cancelled from here.
        services.saveFile(name, bytes);
        return const <String, Object?>{};
      case 'notify':
        final message = request['message'];
        if (message is String) {
          services.notify(message, level: request['level'] as String?);
        }
        return const <String, Object?>{};
      default:
        throw _invalid('The DevTools host does not support "$op".');
    }
  }

  static InspectorClientException _invalid(String message) =>
      InspectorClientException(ErrorCodes.invalidRequest, message);

  String get _theme => darkTheme.value ? 'dark' : 'light';

  void _onConnection() {
    if (connection.value.isConnected) {
      _justConnected = true;
      scheduleMicrotask(() => _justConnected = false);
    }
    _sendConnection();
  }

  void _sendConnection() {
    if (!_ready) return;
    final snapshot = connection.value;
    _send({
      'type': 'connection',
      'state': snapshot.state.name,
      if (snapshot.message != null) 'message': snapshot.message,
    });
  }

  void _onDatabases() {
    if (!_ready || _justConnected) return;
    _send({'type': 'event', 'name': InspectorEvents.databasesChanged});
  }

  void _onTheme() {
    if (_ready) _send({'type': 'theme', 'theme': _theme});
  }

  void _send(Map<String, Object?> message) {
    if (!_disposed) post(message);
  }

  /// Stops forwarding; late answers are dropped.
  void dispose() {
    _disposed = true;
    connection.removeListener(_onConnection);
    darkTheme.removeListener(_onTheme);
    unawaited(_databasesSubscription.cancel());
  }
}
