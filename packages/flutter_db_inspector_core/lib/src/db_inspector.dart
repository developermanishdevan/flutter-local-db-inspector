import 'dart:developer' as developer;

import 'package:flutter_db_inspector_protocol/flutter_db_inspector_protocol.dart';

import 'adapter.dart';
import 'config.dart';
import 'registry.dart';
import 'router.dart';
import 'service_extension.dart';

/// A database to expose, for [DbInspector.initialize]'s `databases` list.
///
/// ```dart
/// InspectorDatabase(name: 'app_database', adapter: SqliteAdapter(db))
/// ```
final class InspectorDatabase {
  const InspectorDatabase({
    required this.name,
    required this.adapter,
    this.readOnly = false,
  });

  /// Display name; also the database id clients use (non-identifier
  /// characters become `_`).
  final String name;

  /// Adapter for the storage engine (SQLite, Drift, Isar, Hive, ...).
  final DbAdapter adapter;

  /// Rejects every write to this database, even in full-access mode.
  final bool readOnly;
}

const bool _isProduct = bool.fromEnvironment('dart.vm.product');
const bool _isProfile = bool.fromEnvironment('dart.vm.profile');

/// Public entry point of Flutter DB Inspector.
///
/// ```dart
/// void main() {
///   DbInspector.initialize(enabled: kDebugMode);
///   runApp(const MyApp());
/// }
/// ```
///
/// The inspector is reachable only through the Dart VM service of a debug or
/// profile build. It never opens a network port of its own.
abstract final class DbInspector {
  static final DbRegistry registry = DbRegistry();
  static InspectorConfig _config = const InspectorConfig();

  /// Router used by the VM service extension; exposed for in-process tests.
  static final InspectorRouter router = InspectorRouter(
    registry: registry,
    config: () => _config,
  );

  /// Enables the inspector and registers [databases].
  ///
  /// ```dart
  /// DbInspector.initialize(
  ///   enabled: kDebugMode,
  ///   databases: [
  ///     InspectorDatabase(name: 'app_database', adapter: SqliteAdapter(db)),
  ///     InspectorDatabase(name: 'cache', adapter: HiveAdapter([box])),
  ///   ],
  /// );
  /// ```
  ///
  /// Databases opened later can still be added with [registerDatabase].
  /// When the inspector is disabled, [databases] are not registered (nothing
  /// keeps a reference to them).
  ///
  /// [enabled] defaults to `true` only in debug builds. In release builds the
  /// inspector stays disabled even when `enabled: true` is passed, unless
  /// [allowInReleaseMode] is also set (release builds have no VM service, so
  /// this only matters for custom embedders).
  static void initialize({
    bool enabled = !_isProduct && !_isProfile,
    bool readOnly = false,
    InspectorLimits limits = const InspectorLimits(),
    Set<String> sensitiveColumns = const {},
    bool allowInReleaseMode = false,
    List<InspectorDatabase> databases = const [],
  }) {
    final ids = <String>{};
    for (final db in databases) {
      if (!ids.add(DbRegistry.idFor(db.name))) {
        throw ArgumentError.value(
          db.name,
          'databases',
          'is listed more than once',
        );
      }
    }
    if (!enabled || (_isProduct && !allowInReleaseMode)) {
      _config = _config.copyWith(mode: InspectorMode.disabled);
      return;
    }
    // Register before exposing the extension so the first client sees them.
    for (final db in databases) {
      registerDatabase(
          name: db.name, adapter: db.adapter, readOnly: db.readOnly);
    }
    _config = InspectorConfig(
      mode: readOnly ? InspectorMode.readOnly : InspectorMode.fullAccess,
      limits: limits,
      sensitiveColumns: sensitiveColumns,
    );
    registerInspectorServiceExtension(router);
    developer.log(
      'Flutter DB Inspector enabled (${_config.mode.name})',
      name: 'flutter_db_inspector',
    );
  }

  /// Updates configuration after [initialize].
  static void configure({
    Set<String>? sensitiveColumns,
    bool? readOnly,
    InspectorLimits? limits,
  }) {
    _config = _config.copyWith(
      sensitiveColumns: sensitiveColumns,
      limits: limits,
      mode: _config.mode == InspectorMode.disabled || readOnly == null
          ? null
          : (readOnly ? InspectorMode.readOnly : InspectorMode.fullAccess),
    );
  }

  /// Exposes a database to the inspector. Safe to call before [initialize]
  /// and to repeat with the same adapter (e.g. after hot reload).
  static void registerDatabase({
    required String name,
    required DbAdapter adapter,
    bool readOnly = false,
  }) {
    registry.register(name, adapter, readOnly: readOnly, replace: true);
  }

  static void unregisterDatabase(String name) => registry.unregister(name);

  static InspectorMode get mode => _config.mode;

  static bool get isEnabled => _config.mode != InspectorMode.disabled;
}
