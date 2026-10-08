import '../json.dart';
import '../value.dart';
import 'rows.dart';

/// Parameters of `query.execute`.
final class SqlRequest {
  const SqlRequest({
    required this.sql,
    this.arguments = const [],
    this.allowWrite = false,
    this.maxRows = 100,
  });

  factory SqlRequest.fromJson(JsonMap json) {
    final r = JsonReader(json);
    return SqlRequest(
      sql: r.string('sql'),
      arguments: [for (final a in r.list('arguments')) DbValueCodec.decode(a)],
      allowWrite: r.boolean('allowWrite'),
      maxRows: r.optInt('maxRows') ?? 100,
    );
  }

  final String sql;
  final List<Object?> arguments;

  /// Must be `true` for statements that modify data. Clients set it only
  /// after the user explicitly confirmed.
  final bool allowWrite;
  final int maxRows;

  SqlRequest copyWith({bool? allowWrite, int? maxRows}) => SqlRequest(
        sql: sql,
        arguments: arguments,
        allowWrite: allowWrite ?? this.allowWrite,
        maxRows: maxRows ?? this.maxRows,
      );
}

enum SqlStatementKind { read, write }

/// Result of `query.execute`.
final class SqlResult {
  const SqlResult({
    required this.kind,
    this.columns = const [],
    this.rows = const [],
    this.truncated = false,
    this.affectedRows,
    this.lastInsertId,
    this.elapsed = Duration.zero,
  });

  final SqlStatementKind kind;
  final List<ResultColumn> columns;
  final List<List<Object?>> rows;

  /// True when more rows existed than `maxRows`.
  final bool truncated;
  final int? affectedRows;
  final int? lastInsertId;
  final Duration elapsed;

  SqlResult withElapsed(Duration elapsed) => SqlResult(
        kind: kind,
        columns: columns,
        rows: rows,
        truncated: truncated,
        affectedRows: affectedRows,
        lastInsertId: lastInsertId,
        elapsed: elapsed,
      );

  SqlResult withRows(List<List<Object?>> rows) => SqlResult(
        kind: kind,
        columns: columns,
        rows: rows,
        truncated: truncated,
        affectedRows: affectedRows,
        lastInsertId: lastInsertId,
        elapsed: elapsed,
      );

  JsonMap toJson(
          [ValueEncodingOptions options = const ValueEncodingOptions()]) =>
      {
        'kind': kind.name,
        'columns': [for (final c in columns) c.toJson()],
        'rows': [
          for (final row in rows)
            [for (final v in row) DbValueCodec.encode(v, options)],
        ],
        'rowCount': rows.length,
        'truncated': truncated,
        if (affectedRows != null) 'affectedRows': affectedRows,
        if (lastInsertId != null) 'lastInsertId': lastInsertId,
        'elapsedMs': elapsed.inMicroseconds / 1000,
      };
}
