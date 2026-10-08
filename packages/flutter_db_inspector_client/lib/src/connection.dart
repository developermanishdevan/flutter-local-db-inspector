import 'dart:async';
import 'dart:convert';

import 'package:flutter_db_inspector_protocol/flutter_db_inspector_protocol.dart';
import 'package:vm_service/vm_service.dart';

import 'connect_stub.dart' if (dart.library.io) 'connect_io.dart' as platform;
import 'exception.dart';

/// Lifecycle of an [InspectorConnection].
///
/// ```
/// DISCONNECTED → CONNECTING → (isolate with the extension found) → CONNECTED
/// CONNECTED → IsolateExit (hot restart) → RECONNECTING → ServiceExtensionAdded → CONNECTED
/// any → VM service closed (app stopped) → DISCONNECTED
/// ```
enum InspectorConnectionState {
  disconnected,
  connecting,
  connected,
  reconnecting,
  error,
}

/// An immutable view of the connection.
final class ConnectionSnapshot {
  const ConnectionSnapshot({
    required this.state,
    this.label,
    this.isolateId,
    this.status,
    this.message,
  });

  static const disconnected =
      ConnectionSnapshot(state: InspectorConnectionState.disconnected);

  final InspectorConnectionState state;

  /// What the connection points at (e.g. the app name or VM service URI).
  final String? label;

  /// The isolate exposing the inspector extension, while connected.
  final String? isolateId;

  /// The handshake result, while connected.
  final InspectorStatus? status;

  /// Human readable explanation for `connecting`, `reconnecting` and `error`.
  final String? message;

  bool get isConnected => state == InspectorConnectionState.connected;

  @override
  String toString() => 'ConnectionSnapshot(${state.name}'
      '${isolateId == null ? '' : ', $isolateId'}'
      '${message == null ? '' : ', $message'})';
}

/// Tuning knobs for [InspectorConnection].
final class InspectorConnectionOptions {
  const InspectorConnectionOptions({
    this.requestTimeout = const Duration(seconds: 30),
    this.reconnectWait = const Duration(seconds: 20),
    this.rescanInterval = const Duration(seconds: 2),
    this.log,
  });

  /// How long a single request may take before failing with
  /// [ClientErrorCodes.clientTimeout].
  final Duration requestTimeout;

  /// How long a request made during a hot restart waits for the app.
  final Duration reconnectWait;

  /// Isolate rescan interval while waiting for the extension.
  final Duration rescanInterval;

  /// Optional diagnostics sink.
  final void Function(String message)? log;
}

/// Anything that can send protocol requests and return their `result`.
abstract interface class InspectorRequestSender {
  /// Sends [method] and returns the `result` object. Throws
  /// [InspectorClientException] for protocol and connection errors.
  Future<JsonMap> request(String method, [JsonMap params = const {}]);
}

/// Owns the connection to one running app through an injected [VmService]
/// and keeps it alive across hot restarts.
///
/// * finds the isolate exposing `ext.flutter_db_inspector.request`
///   (`getVM` → `getIsolate.extensionRPCs`), rescanning until the app calls
///   `DbInspector.initialize()`;
/// * adopts it after an `inspector.status` handshake and protocol version
///   check;
/// * `IsolateExit` (hot restart) → reconnecting; `ServiceExtensionAdded` →
///   adopt the new isolate;
/// * requests made while reconnecting wait up to
///   [InspectorConnectionOptions.reconnectWait];
/// * `flutter_db_inspector.databasesChanged` events → [databasesChanged];
/// * VM service closed → disconnected.
///
/// A port of the VS Code extension's `ConnectionManager`. Free of Flutter
/// and `dart:io`, so it runs in DevTools (web), CLIs and tests alike.
class InspectorConnection implements InspectorRequestSender {
  InspectorConnection({this.options = const InspectorConnectionOptions()});

  /// Connects to a VM service URI (`http://127.0.0.1:1234/abc=/` or its
  /// `ws://…/ws` form) and attaches to it. The connection owns the created
  /// [VmService] and disposes it on [disconnect].
  ///
  /// Not available on the web; there, create the [VmService] yourself and
  /// call [attach].
  static Future<InspectorConnection> connectUri(
    String uri, {
    InspectorConnectionOptions options = const InspectorConnectionOptions(),
    String? label,
  }) async {
    final connection = InspectorConnection(options: options);
    final service = await platform.connectToVmService(uri);
    await connection.attach(service, label: label ?? uri, ownsService: true);
    return connection;
  }

  final InspectorConnectionOptions options;

  /// VM service errors meaning "the isolate went away" (hot restart, stop).
  static const _isolateGoneCodes = {
    -32000, // service connection disposed / application error
    -32010, // connection disposed
    -32601, // method not found: extension not (yet) registered
    -32602, // invalid params: unknown isolate id
    105, // isolate must be runnable
    108, // isolate is reloading
    112, // service disappeared
  };

  final _states = StreamController<ConnectionSnapshot>.broadcast(sync: true);
  final _databases = StreamController<void>.broadcast(sync: true);
  final _connectedWaiters = <Completer<void>>{};
  final _subscriptions = <StreamSubscription<Object?>>[];

  VmService? _service;
  bool _ownsService = false;
  String? _label;
  String? _isolateId;
  InspectorStatus? _status;
  InspectorConnectionState _state = InspectorConnectionState.disconnected;
  String? _message;
  int _generation = 0;
  int _requestCounter = 0;
  Timer? _rescanTimer;
  bool _scanning = false;
  String? _handshaking;
  bool _disposed = false;

  /// Fired on every state change (synchronously, in order).
  Stream<ConnectionSnapshot> get onStateChanged => _states.stream;

  /// Fired when the set of databases may have changed: after (re)connecting
  /// and when the app registers or unregisters a database.
  Stream<void> get databasesChanged => _databases.stream;

  ConnectionSnapshot get snapshot => ConnectionSnapshot(
        state: _state,
        label: _label,
        isolateId: _isolateId,
        status: _status,
        message: _message,
      );

  bool get isConnected => _state == InspectorConnectionState.connected;

  /// The attached VM service, if any.
  VmService? get service => _service;

  void _log(String message) => options.log?.call(message);

  void _setState(InspectorConnectionState state, [String? message]) {
    final changed = _state != state || _message != message;
    _state = state;
    _message = message;
    if (state == InspectorConnectionState.connected) {
      for (final waiter in [..._connectedWaiters]) {
        if (!waiter.isCompleted) waiter.complete();
      }
      _connectedWaiters.clear();
    }
    if (changed && !_disposed) {
      _log('state → ${state.name}${message == null ? '' : ' ($message)'}');
      _states.add(snapshot);
    }
  }

  /// Attaches to [service], replacing any current connection, and starts
  /// looking for the app. Completes once the first scan finished; watch
  /// [onStateChanged] for the outcome.
  ///
  /// With [ownsService] the service is disposed on [disconnect].
  Future<void> attach(
    VmService service, {
    String label = 'app',
    bool ownsService = false,
  }) async {
    if (_disposed) throw StateError('InspectorConnection was disposed');
    await _teardown();
    final generation = ++_generation;
    _service = service;
    _ownsService = ownsService;
    _label = label;
    _setState(InspectorConnectionState.connecting, 'Connecting to $label…');

    _subscriptions
      ..add(
        service.onIsolateEvent.listen((e) => _onIsolateEvent(e, generation)),
      )
      ..add(
        service.onExtensionEvent
            .listen((e) => _onExtensionEvent(e, generation)),
      );
    unawaited(
      service.onDone.then((_) {
        if (generation != _generation) return;
        _log('VM service closed');
        unawaited(_teardown(disposeService: false));
        _setState(
          InspectorConnectionState.disconnected,
          'The app stopped or the VM service closed the connection.',
        );
      }),
    );

    await Future.wait([
      _listen(service, EventStreams.kIsolate),
      _listen(service, EventStreams.kExtension),
    ]);
    if (generation != _generation) return;
    await _scanIsolates(generation);
    if (generation == _generation &&
        _isolateId == null &&
        _state == InspectorConnectionState.connecting) {
      _setState(
        InspectorConnectionState.connecting,
        'Waiting for the app to call DbInspector.initialize()…',
      );
      _startRescan(generation);
    }
  }

  /// Looks for the inspector isolate again, e.g. after the host noticed an
  /// isolate change.
  Future<void> rescan() async {
    if (_service == null || isConnected) return;
    await _scanIsolates(_generation);
  }

  /// Detaches from the VM service (disposing it when owned).
  Future<void> disconnect() async {
    _generation++;
    await _teardown();
    _label = null;
    _setState(InspectorConnectionState.disconnected);
  }

  /// Disconnects and closes the streams.
  Future<void> dispose() async {
    if (_disposed) return;
    await disconnect();
    _disposed = true;
    for (final waiter in _connectedWaiters) {
      if (!waiter.isCompleted) {
        waiter.completeError(
          const InspectorClientException(
            ClientErrorCodes.notConnected,
            'The connection was closed.',
          ),
        );
      }
    }
    _connectedWaiters.clear();
    await _states.close();
    await _databases.close();
  }

  Future<void> _teardown({bool disposeService = true}) async {
    _stopRescan();
    final subscriptions = [..._subscriptions];
    _subscriptions.clear();
    final service = _service;
    final owned = _ownsService;
    _service = null;
    _ownsService = false;
    _isolateId = null;
    _status = null;
    for (final s in subscriptions) {
      await s.cancel();
    }
    if (service != null && owned && disposeService) await service.dispose();
  }

  Future<void> _listen(VmService service, String streamId) async {
    try {
      await service.streamListen(streamId).timeout(options.requestTimeout);
    } on RPCError catch (e) {
      // 103: already subscribed (e.g. DevTools shares the connection) — fine.
      if (e.code != RPCErrorKind.kStreamAlreadySubscribed.code) {
        _log('streamListen($streamId) failed: $e');
      }
    } on Object catch (e) {
      _log('streamListen($streamId) failed: $e');
    }
  }

  void _startRescan(int generation) {
    _stopRescan();
    _rescanTimer = Timer.periodic(options.rescanInterval, (_) {
      if (generation != _generation || _isolateId != null) {
        _stopRescan();
        return;
      }
      unawaited(_scanIsolates(generation));
    });
  }

  void _stopRescan() {
    _rescanTimer?.cancel();
    _rescanTimer = null;
  }

  /// Looks for the isolate exposing the inspector extension.
  Future<void> _scanIsolates(int generation) async {
    final service = _service;
    if (service == null || _scanning) return;
    _scanning = true;
    try {
      final vm = await service.getVM().timeout(options.requestTimeout);
      for (final ref in vm.isolates ?? const <IsolateRef>[]) {
        final id = ref.id;
        if (id == null) continue;
        final Isolate isolate;
        try {
          isolate =
              await service.getIsolate(id).timeout(options.requestTimeout);
        } on SentinelException {
          continue; // Exited while scanning.
        }
        if (isolate.extensionRPCs?.contains(serviceExtensionName) ?? false) {
          if (generation == _generation) await _adopt(id, generation);
          return;
        }
      }
    } on Object catch (e) {
      _log('isolate scan failed: $e');
    } finally {
      _scanning = false;
    }
  }

  /// Makes [isolateId] the active isolate after a protocol handshake.
  Future<void> _adopt(String isolateId, int generation) async {
    if (_isolateId == isolateId &&
        (isConnected ||
            _handshaking == isolateId ||
            _state == InspectorConnectionState.error)) {
      return;
    }
    _isolateId = isolateId;
    _handshaking = isolateId;
    _stopRescan();
    try {
      final status = InspectorStatus.fromJson(
        await _rawRequest(Methods.inspectorStatus, const {}),
      );
      if (generation != _generation || _isolateId != isolateId) return;
      if (!status.supportedVersions.any(supportedProtocolVersions.contains)) {
        _setState(
          InspectorConnectionState.error,
          'The app speaks protocol v${status.protocolVersion}; this client '
          'supports v${supportedProtocolVersions.join(', v')}. Update the '
          'client or the flutter_db_inspector package.',
        );
        return;
      }
      _status = status;
      _setState(
        InspectorConnectionState.connected,
        '${_label ?? 'App'} · ${status.mode.name}',
      );
      if (!_disposed) _databases.add(null);
    } on Object catch (e) {
      if (generation != _generation || _isolateId != isolateId) return;
      if (e is InspectorClientException &&
          e.code == ErrorCodes.inspectorDisabled) {
        _setState(
          InspectorConnectionState.error,
          'The inspector is disabled in this build (release mode or '
          'enabled: false).',
        );
        return;
      }
      _isolateId = null;
      _log('handshake failed: $e');
      _setState(InspectorConnectionState.reconnecting, 'Waiting for the app…');
      _startRescan(generation);
    } finally {
      if (_handshaking == isolateId) _handshaking = null;
    }
  }

  void _onIsolateEvent(Event event, int generation) {
    if (generation != _generation) return;
    final id = event.isolate?.id;
    switch (event.kind) {
      case EventKind.kServiceExtensionAdded
          when event.extensionRPC == serviceExtensionName && id != null:
        _log('extension registered on $id');
        unawaited(_adopt(id, generation));
      case EventKind.kIsolateExit when id != null && id == _isolateId:
        // Hot restart (or the isolate died): wait for the extension.
        _isolateId = null;
        _status = null;
        _setState(
          InspectorConnectionState.reconnecting,
          'App restarted — reconnecting…',
        );
        _startRescan(generation);
    }
  }

  void _onExtensionEvent(Event event, int generation) {
    if (generation != _generation) return;
    if (event.extensionKind == InspectorEvents.databasesChanged &&
        event.isolate?.id == _isolateId &&
        !_disposed) {
      _databases.add(null);
    }
  }

  Future<void> _waitUntilConnected(Duration timeout) async {
    if (isConnected) return;
    final waiter = Completer<void>();
    _connectedWaiters.add(waiter);
    try {
      await waiter.future.timeout(timeout);
    } on TimeoutException {
      throw const InspectorClientException(
        ClientErrorCodes.connectionLost,
        'The app did not come back after restarting.',
      );
    } finally {
      _connectedWaiters.remove(waiter);
    }
  }

  /// Sends a protocol request and returns its `result`. Requests made during
  /// a hot restart wait for the app to come back.
  @override
  Future<JsonMap> request(String method, [JsonMap params = const {}]) async {
    if (_state == InspectorConnectionState.reconnecting ||
        (_state == InspectorConnectionState.connecting && _service != null)) {
      await _waitUntilConnected(options.reconnectWait);
    }
    if (!isConnected) {
      throw const InspectorClientException(
        ClientErrorCodes.notConnected,
        'No Flutter app is connected.',
      );
    }
    try {
      return await _rawRequest(method, params);
    } on InspectorClientException catch (e) {
      // A read that raced a hot restart is safe to repeat on the new isolate.
      // Writes are never retried, so they can't be applied twice.
      if (e.code != ClientErrorCodes.connectionLost ||
          !_readMethods.contains(method)) {
        rethrow;
      }
      await _waitUntilConnected(options.reconnectWait);
      return _rawRequest(method, params);
    }
  }

  /// Methods without side effects, retried once after a hot restart.
  static const _readMethods = {
    Methods.inspectorStatus,
    Methods.databaseList,
    Methods.databaseInfo,
    Methods.databaseStats,
    Methods.schemaList,
    Methods.schemaTable,
    Methods.rowsQuery,
    Methods.rowsCount,
    Methods.valueRead,
  };

  Future<JsonMap> _rawRequest(String method, JsonMap params) async {
    final service = _service;
    final isolateId = _isolateId;
    if (service == null || isolateId == null) {
      throw const InspectorClientException(
        ClientErrorCodes.notConnected,
        'No Flutter app is connected.',
      );
    }
    final envelope = InspectorRequest(
      method: method,
      requestId: 'dart-${++_requestCounter}',
      params: params,
    );
    final Response response;
    try {
      response = await service.callServiceExtension(
        serviceExtensionName,
        isolateId: isolateId,
        args: {serviceExtensionRequestParam: jsonEncode(envelope.toJson())},
      ).timeout(options.requestTimeout);
    } on TimeoutException {
      throw InspectorClientException(
        ClientErrorCodes.clientTimeout,
        'The app did not answer $method within '
        '${options.requestTimeout.inMilliseconds} ms.',
      );
    } on Object catch (e) {
      final gone = switch (e) {
        SentinelException() => true,
        RPCError(:final code) => _isolateGoneCodes.contains(code),
        _ => false,
      };
      _log('$method failed: $e');
      if (gone) {
        if (_isolateId == isolateId && isConnected) {
          _isolateId = null;
          _status = null;
          _setState(
            InspectorConnectionState.reconnecting,
            'App restarted — reconnecting…',
          );
          _startRescan(_generation);
        }
        throw const InspectorClientException(
          ClientErrorCodes.connectionLost,
          'The app restarted while the request was running. Try again.',
        );
      }
      throw InspectorClientException(
        ClientErrorCodes.connectionLost,
        e.toString(),
      );
    }
    return _parseResponse(response.json);
  }

  static JsonMap _parseResponse(Map<String, Object?>? json) {
    final InspectorResponse response;
    try {
      response = InspectorResponse.fromJson(json);
    } on InspectorException {
      throw const InspectorClientException(
        ClientErrorCodes.malformedResponse,
        'The app returned a malformed response.',
      );
    }
    return switch (response) {
      InspectorSuccess(:final result) => result,
      InspectorFailure(:final error) =>
        throw InspectorClientException.fromError(error),
    };
  }
}
