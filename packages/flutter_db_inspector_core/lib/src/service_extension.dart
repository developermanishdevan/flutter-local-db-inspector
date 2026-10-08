import 'dart:developer' as developer;

import 'package:flutter_db_inspector_protocol/flutter_db_inspector_protocol.dart';

import 'registry.dart';
import 'router.dart';

bool _registered = false;

/// Registers `ext.flutter_db_inspector.request` on the current isolate.
///
/// Idempotent: static state survives hot reload, and a hot restart starts a
/// fresh isolate where the extension is registered again — clients observe
/// that as a `ServiceExtensionAdded` event and reconnect automatically.
void registerInspectorServiceExtension(InspectorRouter router) {
  if (_registered) return;
  _registered = true;
  final registry = router.registry;
  registry.addListener(() => _postDatabasesChanged(registry));
  try {
    developer.registerExtension(serviceExtensionName, (method, params) async {
      final raw = params[serviceExtensionRequestParam];
      if (raw == null) {
        return developer.ServiceExtensionResponse.error(
          developer.ServiceExtensionResponse.invalidParams,
          'Missing "$serviceExtensionRequestParam" parameter',
        );
      }
      return developer.ServiceExtensionResponse.result(
        await router.handleRaw(raw),
      );
    });
  } on ArgumentError {
    // Already registered on this isolate.
  }
}

void _postDatabasesChanged(DbRegistry registry) {
  developer.postEvent(InspectorEvents.databasesChanged, {
    'databases': [for (final db in registry.databases) db.id],
  });
}
