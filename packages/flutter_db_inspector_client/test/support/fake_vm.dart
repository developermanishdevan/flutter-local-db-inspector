import 'dart:async';
import 'dart:convert';

import 'package:flutter_db_inspector_client/flutter_db_inspector_client.dart';
import 'package:vm_service/vm_service.dart';

/// Answers one protocol request on [isolateId]; returns the `result` or
/// throws [InspectorError] for a protocol failure.
typedef FakeHandler = FutureOr<JsonMap> Function(
  String isolateId,
  String method,
  JsonMap params,
);

/// A scripted Dart VM speaking JSON-RPC to a real [VmService], so the
/// connection logic is tested against vm_service's actual parsing.
class FakeVm {
  FakeVm({FakeHandler? handler}) : handler = handler ?? _defaultHandler {
    service = VmService(_toClient.stream, _onMessage);
  }

  final _toClient = StreamController<String>();
  late final VmService service;

  /// isolate id → registered extensions.
  final isolates = <String, Set<String>>{};
  FakeHandler handler;

  /// Every protocol method received, in order.
  final calls = <String>[];

  /// Isolates whose extension calls never answer.
  final hangingIsolates = <String>{};

  /// Isolate ids that answer extension calls with a Sentinel.
  final collected = <String>{};

  /// When set, `inspector.status` fails with this error.
  InspectorError? statusError;

  int statusProtocol = protocolVersion;
  List<int> statusSupported = supportedProtocolVersions;

  static JsonMap _defaultHandler(String isolate, String method, JsonMap p) =>
      throw InspectorError(ErrorCodes.unsupportedOperation, method);

  void addIsolate(String id, {bool withExtension = true}) {
    isolates[id] = {if (withExtension) serviceExtensionName};
  }

  /// Simulates the app registering the extension (DbInspector.initialize).
  void registerExtension(String id) {
    isolates.putIfAbsent(id, () => <String>{}).add(serviceExtensionName);
    _event('Isolate', {
      'kind': EventKind.kServiceExtensionAdded,
      'isolate': _isolateRef(id),
      'extensionRPC': serviceExtensionName,
    });
  }

  /// Simulates a hot restart: [from] exits, [to] starts and registers.
  void hotRestart(String from, String to) {
    exitIsolate(from);
    registerExtension(to);
  }

  void exitIsolate(String id) {
    isolates.remove(id);
    _event('Isolate',
        {'kind': EventKind.kIsolateExit, 'isolate': _isolateRef(id)});
  }

  void postDatabasesChanged(String isolateId) {
    _event('Extension', {
      'kind': EventKind.kExtension,
      'isolate': _isolateRef(isolateId),
      'extensionKind': InspectorEvents.databasesChanged,
      'extensionData': {
        'databases': ['app_database'],
      },
    });
  }

  /// Simulates the app stopping (WebSocket closed).
  Future<void> close() => _toClient.close();

  JsonMap _isolateRef(String id) =>
      {'type': '@Isolate', 'id': id, 'name': 'main', 'number': id};

  void _event(String streamId, JsonMap event) {
    _send({
      'jsonrpc': '2.0',
      'method': 'streamNotify',
      'params': {
        'streamId': streamId,
        'event': {'type': 'Event', 'timestamp': 0, ...event},
      },
    });
  }

  void _send(JsonMap message) {
    if (!_toClient.isClosed) _toClient.add(jsonEncode(message));
  }

  void _reply(Object? id, JsonMap result) =>
      _send({'jsonrpc': '2.0', 'id': id, 'result': result});

  void _error(Object? id, int code, String message) => _send({
        'jsonrpc': '2.0',
        'id': id,
        'error': {'code': code, 'message': message},
      });

  Future<void> _onMessage(String raw) async {
    final message = (jsonDecode(raw) as Map).cast<String, Object?>();
    final id = message['id'];
    final method = message['method'] as String;
    final params = (message['params'] as Map? ?? {}).cast<String, Object?>();
    // Answer asynchronously, like a real socket.
    await Future<void>.delayed(Duration.zero);
    switch (method) {
      case 'streamListen':
        _reply(id, {'type': 'Success'});
      case 'getVM':
        _reply(id, {
          'type': 'VM',
          'name': 'vm',
          'isolates': [for (final i in isolates.keys) _isolateRef(i)],
        });
      case 'getIsolate':
        final isolateId = params['isolateId']! as String;
        final extensions = isolates[isolateId];
        if (extensions == null) {
          _reply(id, {
            'type': 'Sentinel',
            'kind': 'Collected',
            'valueAsString': '<collected>'
          });
          return;
        }
        _reply(id, {
          ..._isolateRef(isolateId),
          'type': 'Isolate',
          'extensionRPCs': extensions.toList(),
        });
      case serviceExtensionName:
        final isolateId = params['isolateId']! as String;
        if (collected.contains(isolateId)) {
          _reply(id, {
            'type': 'Sentinel',
            'kind': 'Collected',
            'valueAsString': '<collected>'
          });
          return;
        }
        if (!(isolates[isolateId]?.contains(serviceExtensionName) ?? false)) {
          _error(id, -32601, 'Method not found');
          return;
        }
        if (hangingIsolates.contains(isolateId)) return;
        final request =
            (jsonDecode(params[serviceExtensionRequestParam]! as String) as Map)
                .cast<String, Object?>();
        final protocolMethod = request['method']! as String;
        calls.add(protocolMethod);
        final requestParams =
            (request['params'] as Map? ?? {}).cast<String, Object?>();
        JsonMap response;
        try {
          final result = protocolMethod == Methods.inspectorStatus
              ? _status()
              : await handler(isolateId, protocolMethod, requestParams);
          response = InspectorSuccess(
                  requestId: request['requestId']! as String, result: result)
              .toJson();
        } on InspectorError catch (e) {
          response = InspectorFailure(
                  requestId: request['requestId']! as String, error: e)
              .toJson();
        }
        _reply(id, response);
      default:
        _error(id, -32601, 'Method not found: $method');
    }
  }

  JsonMap _status() {
    if (statusError case final error?) throw error;
    return InspectorStatus(
      protocolVersion: statusProtocol,
      supportedVersions: statusSupported,
      packageVersion: '0.1.0',
      mode: InspectorMode.fullAccess,
      methods: const [Methods.databaseList],
      limits: const InspectorLimits(),
    ).toJson();
  }
}
