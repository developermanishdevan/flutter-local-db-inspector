import 'dart:async';

import 'package:flutter_db_inspector_protocol/flutter_db_inspector_protocol.dart';

/// Contract every database engine implements.
///
/// Adapters return raw Dart values (`int`, `double`, `String`, `Uint8List`,
/// `bool`, `DateTime`, `Map`, `List`, `null`, [TruncatedValue]); the runtime
/// owns wire encoding, masking, limits and write permissions. Optional
/// operations default to [ErrorCodes.unsupportedOperation] and must be listed
/// in [capabilities] when implemented.
abstract class DbAdapter {
  /// Engine identifier shown to clients, e.g. `sqlite`, `drift`, `isar`.
  String get type;

  /// How the engine organises data (tables, collections or key/value).
  DbDataModel get dataModel;

  Set<DbCapability> get capabilities;

  Future<DatabaseMetadata> getMetadata();

  Future<SchemaOverview> getSchemaOverview();

  /// Throws [ErrorCodes.tableNotFound] for unknown entities.
  Future<TableSchema> getTableSchema(String table);

  /// Must honour paging and never read unbounded data.
  Future<RowsPage> queryRows(RowsQuery query);

  /// Counts rows matching the query's filters and search.
  Future<int> countRows(RowsQuery query);

  Future<DatabaseStats> getStats() async {
    final overview = await getSchemaOverview();
    return DatabaseStats(
      entities: overview.entities,
      indexCount: overview.indexes.length,
      triggerCount: overview.triggers.length,
      sizeBytes: (await getMetadata()).sizeBytes,
    );
  }

  Future<MutationResult> insertRow(String table, Map<String, Object?> values) =>
      unsupported('insert');

  Future<MutationResult> updateRow(
    String table,
    RowKey key,
    Map<String, Object?> values,
  ) =>
      unsupported('update');

  Future<MutationResult> deleteRow(String table, RowKey key) =>
      unsupported('delete');

  Future<MutationResult> clearTable(String table) => unsupported('clear');

  /// Executes a native query. Implementations must throw
  /// [ErrorCodes.writeNotAllowed] with `{"requiresConfirmation": true}` for
  /// statements that modify data unless [SqlRequest.allowWrite] is set.
  Future<SqlResult> executeSql(SqlRequest request) => unsupported('sql');

  /// Reads a slice of a large value.
  Future<ValueChunk> readValue(ValueRef ref) => unsupported('value.read');

  /// Releases adapter resources. Does not close the underlying database,
  /// which belongs to the application.
  Future<void> dispose() async {}

  Future<T> unsupported<T>(String operation) => Future.error(
        InspectorException(
          ErrorCodes.unsupportedOperation,
          '"$operation" is not supported by the $type adapter',
        ),
      );
}

/// Helpers shared by adapter implementations.
abstract final class AdapterErrors {
  static InspectorException tableNotFound(String table) => InspectorException(
        ErrorCodes.tableNotFound,
        'Table "$table" does not exist',
        {'table': table},
      );

  static InspectorException columnNotFound(String table, String column) =>
      InspectorException(
        ErrorCodes.columnNotFound,
        'Column "$column" does not exist in "$table"',
        {'table': table, 'column': column},
      );

  static InspectorException rowNotFound(String table) => InspectorException(
        ErrorCodes.rowNotFound,
        'The row no longer exists in "$table"',
        {'table': table},
      );

  static InspectorException invalidKey(String table, String reason) =>
      InspectorException(
        ErrorCodes.invalidRequest,
        'Invalid row key for "$table": $reason',
      );

  static InspectorException writeRequiresConfirmation(String statement) =>
      InspectorException(
        ErrorCodes.writeNotAllowed,
        'This statement may modify application data and must be confirmed.',
        {'requiresConfirmation': true, 'statement': statement},
      );
}
