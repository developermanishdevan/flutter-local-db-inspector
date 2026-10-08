import 'dart:typed_data';

import 'package:flutter_db_inspector_protocol/flutter_db_inspector_protocol.dart';

import 'connection.dart';
import 'exception.dart';
import 'json_reader.dart';
import 'results.dart';
import 'values.dart';

/// Typed protocol client. UIs talk to the app only through this class,
/// never through the VM service directly.
///
/// Every method throws [InspectorClientException] for protocol errors,
/// connection problems and malformed responses.
class InspectorClient {
  InspectorClient(this.sender);

  /// Usually an [InspectorConnection].
  final InspectorRequestSender sender;

  Future<T> _call<T>(
    String method,
    JsonMap params,
    T Function(JsonMap result) parse,
  ) async {
    final result = await sender.request(method, params);
    try {
      return parse(result);
    } on InspectorClientException {
      rethrow;
    } on Object catch (e) {
      // FormatException from client parsing, InspectorException from
      // protocol models, TypeError from unexpected shapes.
      throw InspectorClientException(
        ClientErrorCodes.malformedResponse,
        'Unexpected $method result: $e',
      );
    }
  }

  Future<InspectorStatus> status() =>
      _call(Methods.inspectorStatus, const {}, InspectorStatus.fromJson);

  Future<List<DatabaseDescriptor>> listDatabases() => _call(
        Methods.databaseList,
        const {},
        (r) =>
            ResponseReader(r).objects('databases', DatabaseDescriptor.fromJson),
      );

  Future<DatabaseInfo> databaseInfo(String databaseId) => _call(
        Methods.databaseInfo,
        {'databaseId': databaseId},
        DatabaseInfo.fromJson,
      );

  Future<DatabaseStats> stats(String databaseId) => _call(
        Methods.databaseStats,
        {'databaseId': databaseId},
        DatabaseStats.fromJson,
      );

  Future<SchemaOverview> schema(String databaseId) => _call(
        Methods.schemaList,
        {'databaseId': databaseId},
        SchemaOverview.fromJson,
      );

  Future<TableSchemaResult> tableSchema(String databaseId, String table) =>
      _call(
        Methods.schemaTable,
        {'databaseId': databaseId, 'table': table},
        TableSchemaResult.fromJson,
      );

  static JsonMap _rowsParams(
    String databaseId,
    String table,
    List<RowFilter> filters,
    List<RowSort> sort,
    String? search,
  ) {
    final trimmed = search?.trim();
    return {
      'databaseId': databaseId,
      'table': table,
      if (filters.isNotEmpty) 'filters': [for (final f in filters) f.toJson()],
      if (sort.isNotEmpty) 'sort': [for (final s in sort) s.toJson()],
      if (trimmed != null && trimmed.isNotEmpty) 'search': trimmed,
    };
  }

  /// One page of rows. [pageSize] defaults to the app's configured default.
  Future<RowsPageResult> queryRows(
    String databaseId,
    String table, {
    int page = 0,
    int? pageSize,
    List<RowFilter> filters = const [],
    List<RowSort> sort = const [],
    String? search,
  }) =>
      _call(
        Methods.rowsQuery,
        {
          ..._rowsParams(databaseId, table, filters, sort, search),
          'page': page,
          if (pageSize != null) 'pageSize': pageSize,
        },
        RowsPageResult.fromJson,
      );

  Future<int> countRows(
    String databaseId,
    String table, {
    List<RowFilter> filters = const [],
    String? search,
  }) =>
      _call(
        Methods.rowsCount,
        _rowsParams(databaseId, table, filters, const [], search),
        (r) => ResponseReader(r).optInt('count') ?? 0,
      );

  static JsonMap _values(Map<String, WireValue> values) =>
      {for (final e in values.entries) e.key: e.value.toJson()};

  Future<WriteResult> insertRow(
    String databaseId,
    String table,
    Map<String, WireValue> values,
  ) =>
      _call(
        Methods.rowInsert,
        {'databaseId': databaseId, 'table': table, 'values': _values(values)},
        WriteResult.fromJson,
      );

  Future<WriteResult> updateRow(
    String databaseId,
    String table,
    WireRowKey key,
    Map<String, WireValue> values,
  ) =>
      _call(
        Methods.rowUpdate,
        {
          'databaseId': databaseId,
          'table': table,
          'key': key,
          'values': _values(values),
        },
        WriteResult.fromJson,
      );

  Future<WriteResult> deleteRow(
    String databaseId,
    String table,
    WireRowKey key,
  ) =>
      _call(
        Methods.rowDelete,
        {'databaseId': databaseId, 'table': table, 'key': key},
        WriteResult.fromJson,
      );

  Future<WriteResult> clearTable(String databaseId, String table) => _call(
        Methods.tableClear,
        {'databaseId': databaseId, 'table': table},
        WriteResult.fromJson,
      );

  /// Runs one statement. Statements that may modify data fail with
  /// `WRITE_NOT_ALLOWED` and [InspectorClientException.requiresConfirmation]
  /// until resent with [allowWrite] after the user confirmed.
  Future<SqlQueryResult> executeSql(
    String databaseId,
    String sql, {
    bool allowWrite = false,
    int? maxRows,
    List<WireValue> arguments = const [],
  }) =>
      _call(
        Methods.queryExecute,
        {
          'databaseId': databaseId,
          'sql': sql,
          if (arguments.isNotEmpty)
            'arguments': [for (final a in arguments) a.toJson()],
          if (allowWrite) 'allowWrite': true,
          if (maxRows != null) 'maxRows': maxRows,
        },
        SqlQueryResult.fromJson,
      );

  /// Reads one slice of a large value.
  Future<ValueChunkResult> readValue(
    String databaseId, {
    required String table,
    required WireRowKey key,
    required String column,
    int offset = 0,
    int? length,
  }) =>
      _call(
        Methods.valueRead,
        {
          'databaseId': databaseId,
          'table': table,
          'key': key,
          'column': column,
          'offset': offset,
          if (length != null) 'length': length,
        },
        ValueChunkResult.fromJson,
      );

  /// Reads a complete large value by streaming `value.read` chunks, up to
  /// [maxBytes] when given. [isCancelled] is checked between chunks.
  Future<FullValue> readFullValue(
    String databaseId, {
    required String table,
    required WireRowKey key,
    required String column,
    int? maxBytes,
    void Function(int read, int total)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final out = BytesBuilder(copy: false);
    var offset = 0;
    var total = 0;
    var isText = true;
    while (true) {
      final remaining = maxBytes == null ? null : maxBytes - offset;
      final chunk = await readValue(
        databaseId,
        table: table,
        key: key,
        column: column,
        offset: offset,
        length: remaining,
      );
      total = chunk.totalBytes;
      isText = chunk.isText;
      out.add(chunk.bytes);
      offset += chunk.bytes.length;
      onProgress?.call(offset, total);
      if (chunk.done ||
          chunk.bytes.isEmpty ||
          (maxBytes != null && offset >= maxBytes) ||
          (isCancelled?.call() ?? false)) {
        break;
      }
    }
    var bytes = out.takeBytes();
    if (maxBytes != null && bytes.length > maxBytes) {
      bytes = Uint8List.sublistView(bytes, 0, maxBytes);
    }
    return FullValue(bytes: bytes, isText: isText, totalBytes: total);
  }
}
