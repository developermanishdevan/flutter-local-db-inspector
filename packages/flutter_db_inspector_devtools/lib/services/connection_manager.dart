import 'dart:async';

import 'package:devtools_app_shared/service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_db_inspector_client/flutter_db_inspector_client.dart';
import 'package:vm_service/vm_service.dart';

/// Where the VM service comes from. In DevTools this is the extension's
/// `serviceManager`; tests provide their own.
abstract interface class VmServiceSource {
  /// Notifies when the VM service connection opens or closes.
  Listenable get changes;

  /// The connected VM service, or `null` while there is none.
  VmService? get service;

  /// Human readable name of the connected app.
  String get label;
}

/// Adapts DevTools' [ServiceManager] (from `devtools_app_shared`).
class ServiceManagerSource implements VmServiceSource {
  ServiceManagerSource(this.manager);

  final ServiceManager<VmService> manager;

  @override
  Listenable get changes => manager.connectedState;

  @override
  VmService? get service =>
      manager.connectedState.value.connected ? manager.service : null;

  @override
  String get label => 'the app';
}

/// Bridges the host's VM service to an [InspectorConnection] and exposes
/// the result to the UI.
///
/// The only place in the extension that touches the VM service; widgets
/// use [client] (an [InspectorClient]) exclusively.
class ConnectionManager {
  ConnectionManager({
    required this.source,
    InspectorConnection? connection,
  })  : connection = connection ?? InspectorConnection(),
        _snapshot = ValueNotifier(ConnectionSnapshot.disconnected) {
    client = InspectorClient(this.connection);
  }

  final VmServiceSource source;
  final InspectorConnection connection;
  late final InspectorClient client;

  final ValueNotifier<ConnectionSnapshot> _snapshot;
  StreamSubscription<ConnectionSnapshot>? _stateSubscription;
  VmService? _attached;
  bool _started = false;

  /// The current connection state.
  ValueListenable<ConnectionSnapshot> get snapshot => _snapshot;

  /// Fires when databases may have changed (after (re)connecting and on
  /// `databasesChanged` events).
  Stream<void> get databasesChanged => connection.databasesChanged;

  /// Starts following [source].
  void start() {
    if (_started) return;
    _started = true;
    _stateSubscription = connection.onStateChanged.listen((s) {
      _snapshot.value = s;
    });
    source.changes.addListener(_sync);
    _sync();
  }

  /// Re-attaches to the current VM service (e.g. after an error).
  Future<void> retry() async {
    _attached = null;
    await _syncNow();
  }

  void _sync() => unawaited(_syncNow());

  Future<void> _syncNow() async {
    final service = source.service;
    if (service == null) {
      if (_attached != null) {
        _attached = null;
        await connection.disconnect();
      }
      _snapshot.value = const ConnectionSnapshot(
        state: InspectorConnectionState.disconnected,
        message: 'Waiting for a running app. Start your app in debug mode '
            'and connect DevTools to it.',
      );
      return;
    }
    if (identical(service, _attached)) return;
    _attached = service;
    await connection.attach(service, label: source.label);
  }

  Future<void> dispose() async {
    source.changes.removeListener(_sync);
    await _stateSubscription?.cancel();
    await connection.dispose();
    _snapshot.dispose();
  }
}
