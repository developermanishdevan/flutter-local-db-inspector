import 'package:flutter_db_inspector_protocol/flutter_db_inspector_protocol.dart';

import 'adapter.dart';

/// A database registered with the inspector.
final class RegisteredDatabase {
  const RegisteredDatabase({
    required this.id,
    required this.name,
    required this.adapter,
    this.readOnly = false,
  });

  final String id;
  final String name;
  final DbAdapter adapter;
  final bool readOnly;

  DatabaseDescriptor describe({required bool writable}) => DatabaseDescriptor(
        id: id,
        name: name,
        type: adapter.type,
        capabilities: adapter.capabilities,
        dataModel: adapter.dataModel,
        readOnly: readOnly || !writable,
      );
}

/// Holds the databases exposed to clients.
final class DbRegistry {
  final Map<String, RegisteredDatabase> _databases = {};
  final List<void Function()> _listeners = [];

  /// Called after every registration change.
  void addListener(void Function() listener) => _listeners.add(listener);

  void removeListener(void Function() listener) => _listeners.remove(listener);

  void _notify() {
    for (final listener in List.of(_listeners)) {
      listener();
    }
  }

  /// Derives a stable id from a display name.
  static String idFor(String name) =>
      name.trim().replaceAll(RegExp(r'[^A-Za-z0-9_.\-]+'), '_');

  /// Registers [adapter] under [name].
  ///
  /// Registering the same adapter instance twice is a no-op (convenient when
  /// registration code re-runs); a different adapter under an existing id
  /// throws [StateError]. Use [replace] to swap it deliberately.
  RegisteredDatabase register(
    String name,
    DbAdapter adapter, {
    bool readOnly = false,
    bool replace = false,
  }) {
    final id = idFor(name);
    if (id.isEmpty) {
      throw ArgumentError.value(name, 'name', 'must not be empty');
    }
    final existing = _databases[id];
    if (existing != null && !replace) {
      if (identical(existing.adapter, adapter)) return existing;
      throw StateError('A database with id "$id" is already registered');
    }
    final registered = _databases[id] = RegisteredDatabase(
      id: id,
      name: name,
      adapter: adapter,
      readOnly: readOnly,
    );
    _notify();
    return registered;
  }

  void unregister(String nameOrId) {
    final removed =
        _databases.remove(nameOrId) ?? _databases.remove(idFor(nameOrId));
    if (removed != null) _notify();
  }

  List<RegisteredDatabase> get databases =>
      List.unmodifiable(_databases.values);

  RegisteredDatabase? get(String id) => _databases[id];

  void clear() {
    _databases.clear();
    _notify();
  }
}
