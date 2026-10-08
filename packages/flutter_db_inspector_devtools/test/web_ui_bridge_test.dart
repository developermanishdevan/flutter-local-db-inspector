import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_db_inspector_client/flutter_db_inspector_client.dart';
import 'package:flutter_db_inspector_devtools/services/connection_manager.dart';
import 'package:flutter_db_inspector_devtools/web_ui/web_ui_view.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_backend.dart';

class _Services implements WebUiServices {
  final copies = <(String, String?)>[];
  final files = <(String, Uint8List)>[];
  final notifications = <String>[];
  final logs = <String>[];

  @override
  void copy(String text, {String? label}) => copies.add((text, label));

  @override
  void saveFile(String name, Uint8List bytes) => files.add((name, bytes));

  @override
  void notify(String message, {String? level}) => notifications.add(message);

  @override
  void log(String message) => logs.add(message);
}

class _Harness {
  _Harness({InspectorRequestSender? sender, bool dark = false})
      : darkTheme = ValueNotifier(dark) {
    bridge = WebUiBridge(
      post: sent.add,
      sender: sender ?? FakeBackend(),
      connection: connection,
      databasesChanged: databases.stream,
      darkTheme: darkTheme,
      services: services,
    );
  }

  final sent = <Map<String, Object?>>[];
  final connection = ValueNotifier(const ConnectionSnapshot(
    state: InspectorConnectionState.connecting,
    message: 'Looking for the app…',
  ));
  final databases = StreamController<void>.broadcast(sync: true);
  final ValueNotifier<bool> darkTheme;
  final services = _Services();
  late final WebUiBridge bridge;

  void ready() => bridge.handle({'type': 'ready'});

  /// Sends a request the way the UI does (JSON round trip) and waits for
  /// its result.
  Future<Map<String, Object?>> request(int id, Map<String, Object?> request) {
    bridge.handle(jsonDecode(
        jsonEncode({'type': 'request', 'id': id, 'request': request})));
    return pumpEventQueue().then(
        (_) => sent.lastWhere((m) => m['type'] == 'result' && m['id'] == id));
  }
}

void main() {
  test('ready → init (app mode) then the current connection', () {
    final h = _Harness(dark: true);
    h.connection.value =
        const ConnectionSnapshot(state: InspectorConnectionState.disconnected);
    expect(h.sent, isEmpty, reason: 'nothing before ready');

    h.ready();
    expect(h.sent, [
      {
        'type': 'init',
        'view': 'app',
        'host': 'devtools',
        'pageSize': 50,
        'theme': 'dark',
      },
      {'type': 'connection', 'state': 'disconnected'},
    ]);
    // Every message must survive postMessage (structured clone of JSON).
    expect(jsonDecode(jsonEncode(h.sent)), h.sent);
  });

  test('forwards connection, database events and theme after ready', () async {
    final h = _Harness()..ready();
    h.sent.clear();

    h.connection.value = const ConnectionSnapshot(
      state: InspectorConnectionState.reconnecting,
      message: 'App restarted — reconnecting…',
    );
    h.connection.value = const ConnectionSnapshot(
        state: InspectorConnectionState.connected, message: 'the app · debug');
    // The connection fires databasesChanged right after connecting; the UI
    // already reloads on `connected`.
    h.databases.add(null);
    await pumpEventQueue();
    h.databases.add(null);
    h.darkTheme.value = true;

    expect(h.sent, [
      {
        'type': 'connection',
        'state': 'reconnecting',
        'message': 'App restarted — reconnecting…',
      },
      {
        'type': 'connection',
        'state': 'connected',
        'message': 'the app · debug',
      },
      {'type': 'event', 'name': 'flutter_db_inspector.databasesChanged'},
      {'type': 'theme', 'theme': 'dark'},
    ]);
  });

  test('call → protocol result', () async {
    final backend = FakeBackend();
    final h = _Harness(sender: backend)..ready();

    final reply = await h.request(1, {
      'op': 'call',
      'method': Methods.databaseList,
      'params': <String, Object?>{},
    });
    expect(reply['ok'], isTrue);
    final result = reply['result']! as Map<String, Object?>;
    expect((result['databases']! as List).length, 2);
    expect(backend.calls(Methods.databaseList), ['{}']);
    expect(jsonDecode(jsonEncode(reply)), reply);
  });

  test('call → protocol error with code, message and details', () async {
    final h = _Harness(sender: _Failing())..ready();

    final reply = await h.request(7, {
      'op': 'call',
      'method': Methods.queryExecute,
      'params': {'databaseId': 'app', 'sql': 'DELETE FROM users'},
    });
    expect(reply, {
      'type': 'result',
      'id': 7,
      'ok': false,
      'error': {
        'code': ErrorCodes.writeNotAllowed,
        'message': 'This query may modify application data.',
        'details': {'requiresConfirmation': true},
      },
    });
  });

  test('copy, saveFile and notify use the host services', () async {
    final h = _Harness()..ready();

    expect(
      (await h.request(1, {'op': 'copy', 'text': 'x', 'label': 'cell'}))['ok'],
      isTrue,
    );
    expect(h.services.copies, [('x', 'cell')]);

    final text =
        await h.request(2, {'op': 'saveFile', 'name': 'a.csv', 'text': 'é'});
    expect(text['result'], <String, Object?>{});
    final binary = await h
        .request(3, {'op': 'saveFile', 'name': 'b.bin', 'base64': 'AQID'});
    expect(binary['ok'], isTrue);
    expect(h.services.files.map((f) => f.$1), ['a.csv', 'b.bin']);
    expect(h.services.files[0].$2, [0xc3, 0xa9]);
    expect(h.services.files[1].$2, [1, 2, 3]);

    await h.request(4, {'op': 'notify', 'message': 'Saved', 'level': 'info'});
    expect(h.services.notifications, ['Saved']);

    h.bridge.handle({'type': 'error', 'message': 'boom'});
    expect(h.services.logs.single, contains('boom'));
  });

  test('unknown or malformed requests are answered, never ignored', () async {
    final h = _Harness()..ready();

    for (final (id, request) in [
      (1, {'op': 'rows'}),
      (2, {'op': 'call'}),
      (3, {'op': 'saveFile', 'name': 'x', 'base64': '%%%'}),
      (4, {'op': 'copy'}),
    ]) {
      final reply = await h.request(id, request);
      expect(reply['ok'], isFalse, reason: '$request');
      expect((reply['error']! as Map)['code'], ErrorCodes.invalidRequest);
    }
  });

  test('ignores foreign messages and stops after dispose', () async {
    final h = _Harness();
    h.bridge
      ..handle('not a message')
      ..handle({'type': 'themeUpdate', 'data': <String, Object?>{}});
    expect(h.sent, isEmpty);

    h.ready();
    h.bridge.dispose();
    h.sent.clear();
    h.darkTheme.value = true;
    h.connection.value = ConnectionSnapshot.disconnected;
    h.bridge.handle({'type': 'ready'});
    expect(h.sent, isEmpty);
  });

  testWidgets('outside the browser the view offers the classic UI',
      (tester) async {
    var classic = false;
    final manager = ConnectionManager(source: _NoService());
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: WebUiView(
          connection: manager,
          darkTheme: ValueNotifier(false),
          services: _Services(),
          onUseClassic: () => classic = true,
        ),
      ),
    ));
    await tester.tap(find.text('Use the classic UI'));
    expect(classic, isTrue);
  });
}

class _Failing implements InspectorRequestSender {
  @override
  Future<JsonMap> request(String method, [JsonMap params = const {}]) async =>
      throw const InspectorClientException(
        ErrorCodes.writeNotAllowed,
        'This query may modify application data.',
        {'requiresConfirmation': true},
      );
}

class _NoService implements VmServiceSource {
  @override
  Listenable get changes => ValueNotifier(0);

  @override
  Null get service => null;

  @override
  String get label => 'none';
}
