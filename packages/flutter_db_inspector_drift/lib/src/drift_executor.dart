import 'dart:async';

import 'package:drift/drift.dart';
import 'package:flutter_db_inspector_sqlite/flutter_db_inspector_sqlite.dart';

/// [SqliteExecutor] that runs every statement through a Drift database, so
/// writes made from the inspector go through Drift's own connection and
/// refresh the application's `watch()` streams.
///
/// Writes notify the tables they affect: the table named by [runForTable]
/// when one is in scope (row-level edits), otherwise every table of the
/// database, which is the conservative choice for arbitrary SQL.
final class DriftExecutor implements SqliteExecutor {
  DriftExecutor(this.database);

  /// The application's Drift database.
  final GeneratedDatabase database;

  static final Object _tableZoneKey = Object();

  /// Runs [action] with [table] as the target of every write it performs, so
  /// only streams reading from that table are refreshed.
  ///
  /// The hint is zone scoped, so concurrent requests never see each other's
  /// table.
  static Future<T> runForTable<T>(String table, Future<T> Function() action) =>
      runZoned(action, zoneValues: {_tableZoneKey: table});

  /// Tables a write in the current zone affects.
  Set<TableInfo<Table, Object?>> get affectedTables {
    final hint = Zone.current[_tableZoneKey];
    final all = database.allTables;
    if (hint is String) {
      final matching = {
        for (final t in all)
          if (t.actualTableName == hint) t,
      };
      if (matching.isNotEmpty) return matching;
    }
    return all.toSet();
  }

  /// Converts a raw Dart value into a Drift [Variable].
  static Variable variableFor(Object? value) => switch (value) {
        null => const Variable<Object>(null),
        bool() => Variable<bool>(value),
        int() => Variable<int>(value),
        double() => Variable<double>(value),
        String() => Variable<String>(value),
        Uint8List() => Variable<Uint8List>(value),
        List<int>() => Variable<Uint8List>(Uint8List.fromList(value)),
        BigInt() => Variable<BigInt>(value),
        DateTime() => Variable<DateTime>(value),
        _ => throw ArgumentError.value(
            value,
            'value',
            'Cannot be bound to a SQLite statement',
          ),
      };

  static List<Variable> _variables(List<Object?> arguments) =>
      [for (final a in arguments) variableFor(a)];

  @override
  Future<List<Map<String, Object?>>> select(
    String sql, [
    List<Object?> arguments = const [],
  ]) async {
    final rows = await database
        .customSelect(sql, variables: _variables(arguments))
        .get();
    return [for (final row in rows) Map<String, Object?>.of(row.data)];
  }

  @override
  Future<int> modify(String sql, [List<Object?> arguments = const []]) {
    final keyword = sql.trimLeft().split(RegExp(r'\s')).first.toUpperCase();
    return database.customUpdate(
      sql,
      variables: _variables(arguments),
      updates: affectedTables,
      updateKind: switch (keyword) {
        'UPDATE' => UpdateKind.update,
        'DELETE' => UpdateKind.delete,
        // `WITH ...` may do either; null notifies listeners of every kind.
        _ => null,
      },
    );
  }

  @override
  Future<int> insert(String sql, [List<Object?> arguments = const []]) =>
      database.customInsert(
        sql,
        variables: _variables(arguments),
        updates: affectedTables,
      );

  @override
  Future<void> execute(String sql, [List<Object?> arguments = const []]) async {
    await database.customStatement(sql, arguments);
    database.notifyUpdates({
      for (final table in affectedTables) TableUpdate.onTable(table),
    });
  }

  /// Drift does not expose the file path synchronously; [DriftAdapter]
  /// reports it in the metadata via `PRAGMA database_list` instead.
  @override
  String? get path => null;
}
