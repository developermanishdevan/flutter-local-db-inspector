import 'dart:async';

import 'package:flutter_db_inspector_client/flutter_db_inspector_client.dart';
import 'package:test/test.dart';

import 'support/fake_vm.dart';

const _fast = InspectorConnectionOptions(
  requestTimeout: Duration(seconds: 2),
  reconnectWait: Duration(seconds: 2),
  rescanInterval: Duration(milliseconds: 20),
);

Future<ConnectionSnapshot> _waitFor(
  InspectorConnection connection,
  bool Function(ConnectionSnapshot) predicate,
) async {
  if (predicate(connection.snapshot)) return connection.snapshot;
  return connection.onStateChanged
      .firstWhere(predicate)
      .timeout(const Duration(seconds: 5));
}

JsonMap _databases(String isolate, String method, JsonMap params) {
  if (method == Methods.databaseList) {
    return {
      'databases': [
        {
          'id': 'app_database',
          'name': 'app_database',
          'type': 'sqlite',
          'capabilities': ['read', 'sql'],
          'dataModel': 'relational',
          'readOnly': false,
        },
      ],
      'isolate': isolate,
    };
  }
  throw const InspectorError(
      ErrorCodes.tableNotFound, 'Table "x" does not exist', {'table': 'x'});
}

void main() {
  late FakeVm vm;
  late InspectorConnection connection;

  setUp(() {
    vm = FakeVm(handler: _databases);
    connection = InspectorConnection(options: _fast);
  });

  tearDown(() async {
    await connection.dispose();
    await vm.close();
  });

  test('finds the isolate exposing the extension and handshakes', () async {
    vm
      ..addIsolate('isolates/1', withExtension: false)
      ..addIsolate('isolates/2');
    final states = <InspectorConnectionState>[];
    connection.onStateChanged.listen((s) => states.add(s.state));
    final databases = connection.databasesChanged.first;
    await connection.attach(vm.service, label: 'demo');
    final s = await _waitFor(connection, (s) => s.isConnected);
    expect(s.isolateId, 'isolates/2');
    expect(s.status!.protocolVersion, 1);
    expect(s.message, 'demo · fullAccess');
    expect(states.first, InspectorConnectionState.connecting);
    await databases.timeout(const Duration(seconds: 1));
    expect(vm.calls, [Methods.inspectorStatus]);
  });

  test('waits for DbInspector.initialize(), then connects', () async {
    vm.addIsolate('isolates/1', withExtension: false);
    await connection.attach(vm.service);
    expect(connection.snapshot.state, InspectorConnectionState.connecting);
    expect(connection.snapshot.message, contains('DbInspector.initialize'));
    vm.registerExtension('isolates/1');
    final s = await _waitFor(connection, (s) => s.isConnected);
    expect(s.isolateId, 'isolates/1');
  });

  test('rescans when the extension appears without an event', () async {
    vm.addIsolate('isolates/1', withExtension: false);
    await connection.attach(vm.service);
    vm.isolates['isolates/1']!.add(serviceExtensionName);
    final s = await _waitFor(connection, (s) => s.isConnected);
    expect(s.isolateId, 'isolates/1');
  });

  test('protocol mismatch is an error', () async {
    vm
      ..addIsolate('isolates/1')
      ..statusProtocol = 2
      ..statusSupported = [2];
    await connection.attach(vm.service);
    final s = await _waitFor(
        connection, (s) => s.state == InspectorConnectionState.error);
    expect(s.message, contains('protocol v2'));
  });

  test('disabled inspector is an error', () async {
    vm
      ..addIsolate('isolates/1')
      ..statusError =
          const InspectorError(ErrorCodes.inspectorDisabled, 'disabled');
    await connection.attach(vm.service);
    final s = await _waitFor(
        connection, (s) => s.state == InspectorConnectionState.error);
    expect(s.message, contains('disabled'));
  });

  test('protocol errors become InspectorClientException', () async {
    vm.addIsolate('isolates/1');
    await connection.attach(vm.service);
    await _waitFor(connection, (s) => s.isConnected);
    await expectLater(
      connection.request(Methods.rowsQuery, {'table': 'x'}),
      throwsA(isA<InspectorClientException>()
          .having((e) => e.code, 'code', ErrorCodes.tableNotFound)
          .having((e) => e.details['table'], 'details', 'x')),
    );
  });

  test('hot restart: reconnecting, then adopts the new isolate', () async {
    vm.addIsolate('isolates/1');
    await connection.attach(vm.service);
    await _waitFor(connection, (s) => s.isConnected);
    final reconnecting = _waitFor(
        connection, (s) => s.state == InspectorConnectionState.reconnecting);
    vm.exitIsolate('isolates/1');
    await reconnecting;
    // A request made now waits for the app to come back.
    final pending = connection.request(Methods.databaseList);
    vm.registerExtension('isolates/2');
    final result = await pending;
    expect(result['isolate'], 'isolates/2');
    expect(connection.snapshot.isolateId, 'isolates/2');
  });

  test('databasesChanged events from the active isolate are forwarded',
      () async {
    vm.addIsolate('isolates/1');
    await connection.attach(vm.service);
    await _waitFor(connection, (s) => s.isConnected);
    var count = 0;
    connection.databasesChanged.listen((_) => count++);
    vm
      ..postDatabasesChanged('isolates/other')
      ..postDatabasesChanged('isolates/1');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(count, 1);
  });

  test('isolate gone during a request → reconnecting + CONNECTION_LOST',
      () async {
    vm.addIsolate('isolates/1');
    await connection.attach(vm.service);
    await _waitFor(connection, (s) => s.isConnected);
    vm.collected.add('isolates/1');
    await expectLater(
      connection.request(Methods.databaseList),
      throwsA(isA<InspectorClientException>()
          .having((e) => e.code, 'code', ClientErrorCodes.connectionLost)),
    );
    // The rescan re-adopts the isolate once it answers again.
    vm.collected.clear();
    await _waitFor(connection, (s) => s.isConnected);
  });

  test('request timeout → CLIENT_TIMEOUT', () async {
    vm.addIsolate('isolates/1');
    final c = InspectorConnection(
      options: const InspectorConnectionOptions(
        requestTimeout: Duration(milliseconds: 200),
      ),
    );
    addTearDown(c.dispose);
    await c.attach(vm.service);
    await _waitFor(c, (s) => s.isConnected);
    vm.hangingIsolates.add('isolates/1');
    await expectLater(
      c.request(Methods.databaseList),
      throwsA(isA<InspectorClientException>()
          .having((e) => e.code, 'code', ClientErrorCodes.clientTimeout)),
    );
  });

  test('requests while reconnecting give up after reconnectWait', () async {
    vm.addIsolate('isolates/1');
    final c = InspectorConnection(
      options: const InspectorConnectionOptions(
        reconnectWait: Duration(milliseconds: 200),
        rescanInterval: Duration(milliseconds: 20),
      ),
    );
    addTearDown(c.dispose);
    await c.attach(vm.service);
    await _waitFor(c, (s) => s.isConnected);
    vm.exitIsolate('isolates/1');
    await _waitFor(c, (s) => s.state == InspectorConnectionState.reconnecting);
    await expectLater(
      c.request(Methods.databaseList),
      throwsA(isA<InspectorClientException>()
          .having((e) => e.code, 'code', ClientErrorCodes.connectionLost)),
    );
  });

  test('VM service closed → disconnected; requests fail fast', () async {
    vm.addIsolate('isolates/1');
    await connection.attach(vm.service);
    await _waitFor(connection, (s) => s.isConnected);
    final disconnected = _waitFor(
        connection, (s) => s.state == InspectorConnectionState.disconnected);
    await vm.close();
    final s = await disconnected;
    expect(s.message, contains('stopped'));
    await expectLater(
      connection.request(Methods.databaseList),
      throwsA(isA<InspectorClientException>()
          .having((e) => e.code, 'code', ClientErrorCodes.notConnected)),
    );
  });

  test('disconnect() detaches and ignores later events', () async {
    vm.addIsolate('isolates/1');
    await connection.attach(vm.service);
    await _waitFor(connection, (s) => s.isConnected);
    await connection.disconnect();
    expect(connection.snapshot, isA<ConnectionSnapshot>());
    expect(connection.snapshot.state, InspectorConnectionState.disconnected);
    vm.registerExtension('isolates/2');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(connection.snapshot.state, InspectorConnectionState.disconnected);
  });

  test('vmServiceWebSocketUri normalizes printed URIs', () {
    expect(vmServiceWebSocketUri('http://127.0.0.1:8181/abc=/').toString(),
        'ws://127.0.0.1:8181/abc=/ws');
    expect(vmServiceWebSocketUri('http://127.0.0.1:8181/abc=').toString(),
        'ws://127.0.0.1:8181/abc=/ws');
    expect(vmServiceWebSocketUri('ws://127.0.0.1:8181/abc=/ws').toString(),
        'ws://127.0.0.1:8181/abc=/ws');
  });
}
