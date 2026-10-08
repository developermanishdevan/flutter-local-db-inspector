import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_db_inspector_protocol/flutter_db_inspector_protocol.dart';

import 'json_reader.dart';
import 'values.dart';

/// A row key as sent by the runtime (e.g. `{"rowid": 42}`). Clients treat it
/// as opaque and send it back unchanged.
typedef WireRowKey = JsonMap;

/// Result of `database.info`.
final class DatabaseInfo {
  const DatabaseInfo({required this.database, required this.metadata});

  factory DatabaseInfo.fromJson(JsonMap json) {
    final r = ResponseReader(json);
    return DatabaseInfo(
      database: DatabaseDescriptor.fromJson(r.map('database')),
      metadata: DatabaseMetadata.fromJson(r.optMap('metadata') ?? const {}),
    );
  }

  final DatabaseDescriptor database;
  final DatabaseMetadata metadata;
}

/// Result of `schema.table`.
final class TableSchemaResult {
  const TableSchemaResult({
    required this.schema,
    this.sensitiveColumns = const {},
  });

  factory TableSchemaResult.fromJson(JsonMap json) {
    final r = ResponseReader(json);
    return TableSchemaResult(
      schema: TableSchema.fromJson(r.map('schema')),
      sensitiveColumns: r.strings('sensitiveColumns').toSet(),
    );
  }

  final TableSchema schema;

  /// Columns the app masks; they never leave the device.
  final Set<String> sensitiveColumns;
}

/// One row of `rows.query`: wire values in column order plus its key.
final class WireRow {
  const WireRow({required this.values, this.key});

  factory WireRow.fromJson(JsonMap json) {
    final r = ResponseReader(json);
    return WireRow(
      key: r.optMap('key'),
      values: [for (final v in r.list('values')) WireValue.fromJson(v)],
    );
  }

  /// `null` when the row cannot be addressed (read-only).
  final WireRowKey? key;
  final List<WireValue> values;
}

/// Result of `rows.query`.
final class RowsPageResult {
  const RowsPageResult({
    required this.columns,
    required this.rows,
    required this.page,
    required this.pageSize,
    this.total,
  });

  factory RowsPageResult.fromJson(JsonMap json) {
    final r = ResponseReader(json);
    return RowsPageResult(
      columns: r.objects('columns', ResultColumn.fromJson),
      rows: r.objects('rows', WireRow.fromJson),
      page: r.optInt('page') ?? 0,
      pageSize: r.optInt('pageSize') ?? 0,
      total: r.optInt('total'),
    );
  }

  final List<ResultColumn> columns;
  final List<WireRow> rows;
  final int page;
  final int pageSize;

  /// Total number of matching rows, when the engine knows it.
  final int? total;
}

/// Result of `row.insert`, `row.update`, `row.delete` and `table.clear`.
final class WriteResult {
  const WriteResult({required this.affectedRows, this.insertedKey});

  factory WriteResult.fromJson(JsonMap json) {
    final r = ResponseReader(json);
    return WriteResult(
      affectedRows: r.optInt('affectedRows') ?? 0,
      insertedKey: r.optMap('insertedKey'),
    );
  }

  final int affectedRows;
  final WireRowKey? insertedKey;
}

/// Result of `query.execute`.
final class SqlQueryResult {
  const SqlQueryResult({
    required this.kind,
    this.columns = const [],
    this.rows = const [],
    this.rowCount = 0,
    this.truncated = false,
    this.affectedRows,
    this.lastInsertId,
    this.elapsedMs = 0,
  });

  factory SqlQueryResult.fromJson(JsonMap json) {
    final r = ResponseReader(json);
    final rows = [
      for (final row in r.list('rows'))
        if (row is List)
          [for (final v in row) WireValue.fromJson(v)]
        else
          throw const FormatException('"rows" must contain lists'),
    ];
    return SqlQueryResult(
      kind: r.optString('kind') == 'write'
          ? SqlStatementKind.write
          : SqlStatementKind.read,
      columns: r.objects('columns', ResultColumn.fromJson),
      rows: rows,
      rowCount: r.optInt('rowCount') ?? rows.length,
      truncated: r.boolean('truncated'),
      affectedRows: r.optInt('affectedRows'),
      lastInsertId: r.optInt('lastInsertId'),
      elapsedMs: switch (json['elapsedMs']) {
        final num n => n.toDouble(),
        _ => 0,
      },
    );
  }

  final SqlStatementKind kind;
  final List<ResultColumn> columns;
  final List<List<WireValue>> rows;
  final int rowCount;

  /// More rows existed than `maxRows`.
  final bool truncated;
  final int? affectedRows;
  final int? lastInsertId;
  final double elapsedMs;
}

/// Result of `value.read`: one slice of a large value.
final class ValueChunkResult {
  const ValueChunkResult({
    required this.bytes,
    required this.offset,
    required this.totalBytes,
    required this.isText,
    required this.done,
  });

  factory ValueChunkResult.fromJson(JsonMap json) {
    final r = ResponseReader(json);
    final Uint8List bytes;
    try {
      bytes = base64Decode(r.optString('base64') ?? '');
    } on FormatException {
      throw const FormatException('"base64" is not valid base64');
    }
    final offset = r.optInt('offset') ?? 0;
    final total = r.optInt('totalBytes') ?? bytes.length;
    return ValueChunkResult(
      bytes: bytes,
      offset: offset,
      totalBytes: total,
      isText: r.boolean('isText'),
      done: r.boolean('done', fallback: offset + bytes.length >= total),
    );
  }

  final Uint8List bytes;
  final int offset;
  final int totalBytes;
  final bool isText;
  final bool done;
}

/// A large value read completely (or up to a byte limit) with `value.read`.
final class FullValue {
  const FullValue({
    required this.bytes,
    required this.isText,
    required this.totalBytes,
  });

  final Uint8List bytes;
  final bool isText;
  final int totalBytes;

  /// Whether every byte was read.
  bool get complete => bytes.length >= totalBytes;

  /// The value decoded as UTF-8 (for text values). A partial read may end
  /// inside a multi-byte sequence, which is replaced, not rejected.
  String? get text => isText ? utf8.decode(bytes, allowMalformed: true) : null;
}
