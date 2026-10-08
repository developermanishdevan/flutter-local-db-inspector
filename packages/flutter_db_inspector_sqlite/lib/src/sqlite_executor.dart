import 'package:sqflite_common/sqlite_api.dart';

/// Minimal SQLite access the adapter needs. Implement it to inspect SQLite
/// through any library (sqflite, sqlite3, Drift, ...).
abstract interface class SqliteExecutor {
  /// Runs a statement returning rows.
  Future<List<Map<String, Object?>>> select(
    String sql, [
    List<Object?> arguments,
  ]);

  /// Runs a data-modifying statement and returns the number of changed rows.
  Future<int> modify(String sql, [List<Object?> arguments]);

  /// Runs an `INSERT` and returns the last inserted rowid.
  Future<int> insert(String sql, [List<Object?> arguments]);

  /// Runs any other statement (DDL, PRAGMA assignments, ...).
  Future<void> execute(String sql, [List<Object?> arguments]);

  /// Database file path, when known.
  String? get path;
}

/// [SqliteExecutor] over a `sqflite` / `sqflite_common_ffi` database or
/// transaction. Floor exposes the same type via `database.database`.
final class SqfliteExecutor implements SqliteExecutor {
  const SqfliteExecutor(this.database);

  final DatabaseExecutor database;

  @override
  Future<List<Map<String, Object?>>> select(
    String sql, [
    List<Object?> arguments = const [],
  ]) =>
      database.rawQuery(sql, arguments);

  @override
  Future<int> modify(String sql, [List<Object?> arguments = const []]) =>
      database.rawUpdate(sql, arguments);

  @override
  Future<int> insert(String sql, [List<Object?> arguments = const []]) =>
      database.rawInsert(sql, arguments);

  @override
  Future<void> execute(String sql, [List<Object?> arguments = const []]) =>
      database.execute(sql, arguments);

  @override
  String? get path {
    final db = database;
    return db is Database ? db.path : null;
  }
}
