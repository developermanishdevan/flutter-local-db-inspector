import 'package:drift/drift.dart';
import 'package:flutter_db_inspector_core/flutter_db_inspector_core.dart';
import 'package:flutter_db_inspector_sqlite/flutter_db_inspector_sqlite.dart';

import 'drift_executor.dart';

/// Inspects a Drift database (Moor users must migrate to Drift first).
///
/// ```dart
/// DbInspector.registerDatabase(name: 'app', adapter: DriftAdapter(db));
/// ```
///
/// All browsing, editing and SQL goes through Drift's own connection, so the
/// inspector never opens a second handle on the file. Row edits notify the
/// edited table and SQL console writes notify every table, so the app's
/// `watch()` streams refresh immediately.
class DriftAdapter extends SqliteAdapter {
  DriftAdapter(GeneratedDatabase database)
      : this.executor(DriftExecutor(database));

  DriftAdapter.executor(DriftExecutor super.executor)
      : super.executor(type: 'drift');

  /// The application's Drift database.
  GeneratedDatabase get database => (executor as DriftExecutor).database;

  @override
  Future<DatabaseMetadata> getMetadata() async {
    final base = await super.getMetadata();
    return guard(() async {
      final files = await executor.select('PRAGMA database_list');
      final mainFile = files
          .where((f) => f['name'] == 'main')
          .map((f) => f['file'])
          .whereType<String>()
          .where((f) => f.isNotEmpty)
          .firstOrNull;
      return DatabaseMetadata(
        engine: base.engine,
        engineVersion: base.engineVersion,
        path: base.path ?? mainFile,
        sizeBytes: base.sizeBytes,
        extra: {
          ...base.extra,
          'schemaVersion': database.schemaVersion,
          'driftTables': {
            for (final t in database.allTables)
              t.actualTableName: t.runtimeType.toString(),
          },
        },
      );
    });
  }

  @override
  Future<MutationResult> insertRow(String table, Map<String, Object?> values) =>
      DriftExecutor.runForTable(table, () => super.insertRow(table, values));

  @override
  Future<MutationResult> updateRow(
    String table,
    RowKey key,
    Map<String, Object?> values,
  ) =>
      DriftExecutor.runForTable(
          table, () => super.updateRow(table, key, values));

  @override
  Future<MutationResult> deleteRow(String table, RowKey key) =>
      DriftExecutor.runForTable(table, () => super.deleteRow(table, key));

  @override
  Future<MutationResult> clearTable(String table) =>
      DriftExecutor.runForTable(table, () => super.clearTable(table));
}
