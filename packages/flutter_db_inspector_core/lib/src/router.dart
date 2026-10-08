import 'dart:async';
import 'dart:convert';

import 'package:flutter_db_inspector_protocol/flutter_db_inspector_protocol.dart';

import 'config.dart';
import 'registry.dart';

/// Version of this runtime package, reported by `inspector.status`.
const String packageVersion = '1.0.0';

/// Builds a result for the given value-encoding budget, so oversized
/// responses can be re-encoded with smaller previews.
typedef _ResultBuilder = JsonMap Function(ValueEncodingOptions options);

typedef _Handler = Future<_ResultBuilder> Function(InspectorRequest request);

/// Routes protocol requests to adapters.
///
/// The router is the single place that enforces permissions, capabilities,
/// masking, paging limits, timeouts and response size, so adapters only deal
/// with their engine.
final class InspectorRouter {
  InspectorRouter({
    required this.registry,
    required InspectorConfig Function() config,
  }) : _config = config {
    _handlers = {
      Methods.inspectorStatus: _status,
      Methods.databaseList: _databaseList,
      Methods.databaseInfo: _databaseInfo,
      Methods.databaseStats: _databaseStats,
      Methods.schemaList: _schemaList,
      Methods.schemaTable: _schemaTable,
      Methods.rowsQuery: _rowsQuery,
      Methods.rowsCount: _rowsCount,
      Methods.rowInsert: _rowInsert,
      Methods.rowUpdate: _rowUpdate,
      Methods.rowDelete: _rowDelete,
      Methods.tableClear: _tableClear,
      Methods.queryExecute: _queryExecute,
      Methods.valueRead: _valueRead,
    };
  }

  final DbRegistry registry;
  final InspectorConfig Function() _config;
  late final Map<String, _Handler> _handlers;

  InspectorConfig get config => _config();

  /// Methods this runtime answers.
  List<String> get methods => List.unmodifiable(_handlers.keys);

  /// Decodes a raw JSON request and returns the encoded JSON response.
  /// Never throws.
  Future<String> handleRaw(String raw) async {
    InspectorRequest request;
    try {
      request = InspectorRequest.fromJson(jsonDecode(raw));
    } on InspectorException catch (e) {
      return jsonEncode(
          InspectorFailure(requestId: '', error: e.error).toJson());
    } on FormatException catch (e) {
      return jsonEncode(
        InspectorFailure(
          requestId: '',
          error: InspectorError(
            ErrorCodes.invalidRequest,
            'Request is not valid JSON: ${e.message}',
          ),
        ).toJson(),
      );
    }
    return jsonEncode((await handle(request)).toJson());
  }

  /// Handles one request. Never throws.
  Future<InspectorResponse> handle(InspectorRequest request) async {
    InspectorFailure fail(InspectorError error) =>
        InspectorFailure(requestId: request.requestId, error: error);

    final config = this.config;
    if (config.mode == InspectorMode.disabled) {
      return fail(const InspectorError(
        ErrorCodes.inspectorDisabled,
        'Flutter DB Inspector is disabled in this build',
      ));
    }
    if (!supportedProtocolVersions.contains(request.version)) {
      return fail(InspectorError(
        ErrorCodes.unsupportedProtocolVersion,
        'Protocol version ${request.version} is not supported',
        {'supportedVersions': supportedProtocolVersions},
      ));
    }
    final handler = _handlers[request.method];
    if (handler == null) {
      return fail(InspectorError(
        ErrorCodes.unsupportedOperation,
        'Unknown method "${request.method}"',
        {'method': request.method},
      ));
    }

    try {
      final timeout = config.limits.queryTimeout;
      final build = await handler(request).timeout(
        timeout,
        onTimeout: () => throw InspectorException(
          ErrorCodes.queryTimeout,
          'The operation did not finish within ${timeout.inMilliseconds} ms',
          {'timeoutMs': timeout.inMilliseconds},
        ),
      );
      return InspectorSuccess(
        requestId: request.requestId,
        result: _fitToBudget(build, config.limits),
      );
    } on InspectorException catch (e) {
      return fail(e.error);
    } on Exception catch (e) {
      return fail(InspectorError(ErrorCodes.queryFailed, _describe(e)));
    } on Error catch (e) {
      return fail(InspectorError(ErrorCodes.internalError, _describe(e)));
    }
  }

  JsonMap _fitToBudget(_ResultBuilder build, InspectorLimits limits) {
    var options =
        ValueEncodingOptions(textPreviewBytes: limits.textPreviewBytes);
    for (var attempt = 0; attempt < 2; attempt++) {
      final result = build(options);
      final size = utf8.encode(jsonEncode(result)).length;
      if (size <= limits.maxResponseBytes) return result;
      options = ValueEncodingOptions.compact;
    }
    throw InspectorException(
      ErrorCodes.resultTooLarge,
      'The response exceeds ${limits.maxResponseBytes} bytes. '
      'Use a smaller page size or select fewer columns.',
      {'maxResponseBytes': limits.maxResponseBytes},
    );
  }

  static String _describe(Object error) {
    final text = error.toString();
    return text.length > 2000 ? '${text.substring(0, 2000)}…' : text;
  }

  // ---------------------------------------------------------------------------
  // Helpers

  RegisteredDatabase _database(InspectorRequest r) {
    final id = r.reader.string('databaseId');
    return registry.get(id) ??
        (throw InspectorException(
          ErrorCodes.databaseNotFound,
          'Database "$id" is not registered',
          {'databaseId': id},
        ));
  }

  void _requireCapability(RegisteredDatabase db, DbCapability capability) {
    if (!db.adapter.capabilities.contains(capability)) {
      throw InspectorException(
        ErrorCodes.unsupportedOperation,
        'The ${db.adapter.type} adapter does not support "${capability.name}"',
        {'capability': capability.name},
      );
    }
  }

  void _requireWritable(RegisteredDatabase db) {
    if (!config.writable || db.readOnly) {
      throw InspectorException(
        ErrorCodes.writeNotAllowed,
        db.readOnly
            ? 'Database "${db.name}" is registered as read-only'
            : 'The inspector is running in read-only mode',
        const {'requiresConfirmation': false},
      );
    }
  }

  void _rejectMaskedColumns(String table, Iterable<String> columns) {
    for (final column in columns) {
      if (config.isSensitive(table, column)) {
        throw InspectorException(
          ErrorCodes.permissionDenied,
          'Column "$table.$column" is marked as sensitive',
          {'table': table, 'column': column},
        );
      }
    }
  }

  RowsQuery _parseRowsQuery(InspectorRequest r) {
    final limits = config.limits;
    final query = RowsQuery.fromJson(r.params);
    final requested = r.reader.optInt('pageSize') ?? limits.defaultPageSize;
    return query.copyWith(
      page: query.page < 0 ? 0 : query.page,
      pageSize: requested.clamp(1, limits.maxPageSize),
      previewBytes: limits.textPreviewBytes,
    );
  }

  /// Parses a rows query and enforces capabilities and masking on it.
  Future<RowsQuery> _prepareRowsQuery(
    RegisteredDatabase db,
    InspectorRequest r,
  ) async {
    var query = _parseRowsQuery(r);
    if (query.filters.isNotEmpty) _requireCapability(db, DbCapability.filter);
    if (query.sort.isNotEmpty) _requireCapability(db, DbCapability.sort);
    if (query.search != null) _requireCapability(db, DbCapability.search);
    _rejectMaskedColumns(query.table, [
      ...query.filters.map((f) => f.column),
      ...query.sort.map((s) => s.column),
    ]);
    if (query.search != null && config.sensitiveColumns.isNotEmpty) {
      // Searching sensitive columns would leak their contents by probing.
      final schema = await db.adapter.getTableSchema(query.table);
      query = query.copyWith(searchExcludedColumns: {
        for (final c in schema.columns)
          if (config.isSensitive(query.table, c.name)) c.name,
      });
    }
    return query;
  }

  // ---------------------------------------------------------------------------
  // Handlers

  Future<_ResultBuilder> _status(InspectorRequest r) async {
    final status = InspectorStatus(
      protocolVersion: protocolVersion,
      supportedVersions: supportedProtocolVersions,
      packageVersion: packageVersion,
      mode: config.mode,
      methods: methods,
      limits: config.limits,
    );
    return (_) => status.toJson();
  }

  Future<_ResultBuilder> _databaseList(InspectorRequest r) async {
    final writable = config.writable;
    final list = [
      for (final db in registry.databases)
        db.describe(writable: writable).toJson(),
    ];
    return (_) => {'databases': list};
  }

  Future<_ResultBuilder> _databaseInfo(InspectorRequest r) async {
    final db = _database(r);
    final metadata = await db.adapter.getMetadata();
    return (_) => {
          'database': db.describe(writable: config.writable).toJson(),
          'metadata': metadata.toJson(),
        };
  }

  Future<_ResultBuilder> _databaseStats(InspectorRequest r) async {
    final stats = await _database(r).adapter.getStats();
    return (_) => stats.toJson();
  }

  Future<_ResultBuilder> _schemaList(InspectorRequest r) async {
    final overview = await _database(r).adapter.getSchemaOverview();
    return (_) => overview.toJson();
  }

  Future<_ResultBuilder> _schemaTable(InspectorRequest r) async {
    final db = _database(r);
    final schema = await db.adapter.getTableSchema(r.reader.string('table'));
    return (_) => {
          'schema': schema.toJson(),
          'sensitiveColumns': [
            for (final c in schema.columns)
              if (config.isSensitive(schema.name, c.name)) c.name,
          ],
        };
  }

  Future<_ResultBuilder> _rowsQuery(InspectorRequest r) async {
    final db = _database(r);
    _requireCapability(db, DbCapability.read);
    final query = await _prepareRowsQuery(db, r);
    final page = await db.adapter.queryRows(query);
    final masked = [
      for (final c in page.columns) config.isSensitive(query.table, c.name),
    ];
    final rows = masked.contains(true)
        ? [
            for (final row in page.rows)
              RowRecord(
                key: row.key,
                values: [
                  for (var i = 0; i < row.values.length; i++)
                    i < masked.length && masked[i]
                        ? const MaskedValue()
                        : row.values[i],
                ],
              ),
          ]
        : page.rows;
    final result = RowsPage(
      columns: page.columns,
      rows: rows,
      page: query.page,
      pageSize: query.pageSize,
      total: page.total,
    );
    return result.toJson;
  }

  Future<_ResultBuilder> _rowsCount(InspectorRequest r) async {
    final db = _database(r);
    _requireCapability(db, DbCapability.read);
    final query = await _prepareRowsQuery(db, r);
    final count = await db.adapter.countRows(query);
    return (_) => {'count': count};
  }

  Future<_ResultBuilder> _rowInsert(InspectorRequest r) async {
    final db = _database(r);
    _requireWritable(db);
    _requireCapability(db, DbCapability.insert);
    final result = await db.adapter.insertRow(
      r.reader.string('table'),
      decodeValues(r.reader.map('values')),
    );
    return (_) => result.toJson();
  }

  Future<_ResultBuilder> _rowUpdate(InspectorRequest r) async {
    final db = _database(r);
    _requireWritable(db);
    _requireCapability(db, DbCapability.update);
    final values = decodeValues(r.reader.map('values'));
    if (values.isEmpty) {
      throw InspectorException(
          ErrorCodes.invalidRequest, 'No values to update');
    }
    final result = await db.adapter.updateRow(
      r.reader.string('table'),
      decodeKey(r.reader.map('key')),
      values,
    );
    return (_) => result.toJson();
  }

  Future<_ResultBuilder> _rowDelete(InspectorRequest r) async {
    final db = _database(r);
    _requireWritable(db);
    _requireCapability(db, DbCapability.delete);
    final result = await db.adapter.deleteRow(
      r.reader.string('table'),
      decodeKey(r.reader.map('key')),
    );
    return (_) => result.toJson();
  }

  Future<_ResultBuilder> _tableClear(InspectorRequest r) async {
    final db = _database(r);
    _requireWritable(db);
    _requireCapability(db, DbCapability.clear);
    final result = await db.adapter.clearTable(r.reader.string('table'));
    return (_) => result.toJson();
  }

  Future<_ResultBuilder> _queryExecute(InspectorRequest r) async {
    final db = _database(r);
    _requireCapability(db, DbCapability.sql);
    final writable = config.writable && !db.readOnly;
    final limits = config.limits;
    var request = SqlRequest.fromJson(r.params);
    request = request.copyWith(
      allowWrite: request.allowWrite && writable,
      maxRows: request.maxRows.clamp(1, limits.maxSqlRows),
    );

    final stopwatch = Stopwatch()..start();
    SqlResult result;
    try {
      result = await db.adapter.executeSql(request);
    } on InspectorException catch (e) {
      if (e.code == ErrorCodes.writeNotAllowed && !writable) {
        _requireWritable(db);
      }
      rethrow;
    }
    result = result.withElapsed(stopwatch.elapsed);

    final masked = [
      for (final c in result.columns) config.isSensitiveName(c.name)
    ];
    if (masked.contains(true)) {
      result = result.withRows([
        for (final row in result.rows)
          [
            for (var i = 0; i < row.length; i++)
              i < masked.length && masked[i] ? const MaskedValue() : row[i],
          ],
      ]);
    }
    return result.toJson;
  }

  Future<_ResultBuilder> _valueRead(InspectorRequest r) async {
    final db = _database(r);
    _requireCapability(db, DbCapability.read);
    var ref = ValueRef.fromJson(r.params);
    _rejectMaskedColumns(ref.table, [ref.column]);
    final chunk = config.limits.blobChunkBytes;
    if (ref.offset < 0) {
      throw InspectorException(
          ErrorCodes.invalidRequest, 'offset must be >= 0');
    }
    ref = ref.withLength(ref.length.clamp(1, chunk));
    final result = await db.adapter.readValue(ref);
    return (_) => result.toJson();
  }
}
